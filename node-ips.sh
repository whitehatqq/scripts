#!/bin/bash
# Сбор с ноды для главного сервера: пары «клиент + IP», попытки торрента и баны блокеров.
# Нода раз в 5 минут складывает их в файл, главный сервер забирает по SSH ключом, который
# умеет только это. Сайты, которые открывают клиенты, никуда не уходят. Журнал Xray скрипт
# только читает: ротацию журнала настраивают отдельно, вместе с логом в ядре.
#
# Строки файла:
#   123456 203.0.113.10                           — пара: клиент и IP
#   T 123456 203.0.113.10 14                      — 14 попыток в TORRENT за 5 минут
#   B 1761660300 tblocker 123456 203.0.113.10 10  — бан: время (unix), источник, клиент, IP, минут
# Источники бана: tblocker (xray-torrent-blocker), p2pban (по поведению), p2pban_extend
# (p2pban продлил бан блокера при повторах)
#
# Установка:  bash node-ips.sh            (спросит публичный ключ главного сервера)
#             NODEIPS_KEY='ssh-ed25519 AAAA…' bash node-ips.sh
# Обновление: bash node-ips.sh            (ключ уже стоит — не спрашивает)
# Удаление:   bash node-ips.sh --remove
set -euo pipefail

user=nodeips
dir=/var/lib/node-ips
log=/var/lib/pg-node/access.log

# Нужен root
[ "$(id -u)" = 0 ] || { echo "Запустите от root"; exit 1; }

# Удаление: пользователь, скрипты, cron и данные
if [ "${1:-}" = "--remove" ]; then
    rm -f /etc/cron.d/node-ips /usr/local/bin/node-ips /usr/local/bin/node-ips-get
    id "$user" >/dev/null 2>&1 && userdel "$user"
    rm -rf "$dir"
    echo "Удалено"
    exit 0
fi

# Лог Xray должен существовать — иначе собирать нечего
[ -f "$log" ] || { echo "Нет $log — в ядре не включён access-лог"; exit 1; }

# Публичный ключ главного сервера: из переменной, из уже установленного или вопросом
key="${NODEIPS_KEY:-}"
if [ -z "$key" ] && [ -f "$dir/.ssh/authorized_keys" ]; then
    key=$(sed -E 's/^restrict,command="[^"]*" //' "$dir/.ssh/authorized_keys" | head -n 1)
fi
while ! printf '%s' "$key" | grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9-]+) [A-Za-z0-9+/=]+( .*)?$'; do
    [ -t 0 ] || { echo "Задайте NODEIPS_KEY"; exit 1; }
    read -rp "Публичный ключ главного сервера (ssh-ed25519 …): " key
done

# Пользователь без пароля: войти можно только ключом и только в одну команду
# Пароль «*» — входа по паролю нет, но учётная запись не заблокирована: заблокированную
# («!» после passwd -l) sshd на части серверов не пускает и по ключу
id "$user" >/dev/null 2>&1 || useradd --system --user-group --home-dir "$dir" --shell /bin/sh "$user"
usermod -p '*' "$user"
mkdir -p "$dir/.ssh" "$dir/out"
printf 'restrict,command="/usr/local/bin/node-ips-get" %s\n' "$key" > "$dir/.ssh/authorized_keys"
chown -R "$user:$user" "$dir"
chmod 700 "$dir/.ssh" && chmod 600 "$dir/.ssh/authorized_keys"
chmod 755 "$dir" && chmod 770 "$dir/out"

# Сборщик: новые строки лога и журналов блокеров → файл с отметкой времени
cat > /usr/local/bin/node-ips <<'EOF'
#!/bin/bash
# Раз в 5 минут: пары «клиент + IP», попытки торрента и баны блокеров
set -eu
export LC_ALL=C
log=/var/lib/pg-node/access.log
state=/var/lib/node-ips
out=$state/out
pos_file=$state/pos

# Один запуск за раз: ручной запуск во время крона дождётся его конца
exec 9>"$state/lock"
flock 9

# Текущий лог: номер файла и размер
cur_inode=$(stat -c %i "$log")
size=$(stat -c %s "$log")

# Где остановились в прошлый раз. Первый запуск — с конца: старый лог не разбираем
read -r inode pos 2>/dev/null < "$pos_file" || { inode=$cur_inode; pos=$size; }

# Лог сменили или обрезали при ротации — читаем новый с начала
if [ "$cur_inode" != "$inode" ] || [ "$size" -lt "$pos" ]; then pos=0; fi

# Забираем новый кусок лога разом — дальше разбираем копию
chunk=$state/chunk
tail -c +"$((pos + 1))" "$log" | head -c "$((size - pos))" > "$chunk"
echo "$cur_inode $size" > "$pos_file"

file="$out/$(date -u +%Y%m%d%H%M).txt"
{
    # Строки «from 203.0.113.10:51234 accepted … [HOP_IN >> TORRENT] email: 123456» →
    # пара «123456 203.0.113.10» и счётчик попыток в TORRENT
    awk '
        / accepted / && /email: / {
            ip = $0; sub(/.* from (tcp:|udp:)?/, "", ip); sub(/ .*/, "", ip)
            sub(/:[0-9]+$/, "", ip); gsub(/\[|\]/, "", ip)
            id = $0; sub(/.*email: /, "", id); sub(/[^0-9].*/, "", id)
            if (id == "" || ip == "127.0.0.1" || ip == "::1") next
            print id " " ip
            if ($0 ~ / (->|>>|==>) TORRENT\]/) torrent[id " " ip]++
        }
        END { for (k in torrent) print "T " k " " torrent[k] }' "$chunk"

    # Баны xray-torrent-blocker: «User 123456 with IP: 1.2.3.4 blocked for 10 minutes».
    # Курсор помнит, где остановились; без курсора берём последние 7 дней
    journalctl -u tblocker --cursor-file="$state/tblocker.cursor" --since "-7 days" -o short-unix --no-pager -q 2>/dev/null \
    | awk '{
        id = ""; ip = ""; m = ""
        for (i = 1; i < NF; i++) {
            if ($i == "User") id = $(i + 1)
            if ($i == "IP:") ip = $(i + 1)
            if ($i == "for") m = $(i + 1)
        }
        if (id ~ /^[0-9]+$/ && ip ~ /^[0-9a-fA-F.:]+$/ && m ~ /^[0-9]+$/) print "B " int($1) " tblocker " id " " ip " " m
    }' || true

    # Баны p2pban: «BAN id=… ip=… ban=60min» — по поведению, «TBLOCKER id=… ip=… ban=360min» —
    # продление бана блокера. Режим наблюдения (DRY) не бан — пропускаем
    journalctl -t p2pban --cursor-file="$state/p2pban.cursor" --since "-7 days" -o short-unix --no-pager -q 2>/dev/null \
    | awk '{
        kind = ""; id = ""; ip = ""; m = ""
        for (i = 1; i <= NF; i++) {
            if ($i == "DRY") next
            if ($i == "BAN") kind = "p2pban"
            if ($i == "TBLOCKER") kind = "p2pban_extend"
            if ($i ~ /^id=/) id = substr($i, 4)
            if ($i ~ /^ip=/) ip = substr($i, 4)
            if ($i ~ /^ban=/) { m = substr($i, 5); sub(/min$/, "", m) }
        }
        if (kind != "" && id ~ /^[0-9]+$/ && ip ~ /^[0-9a-fA-F.:]+$/ && m ~ /^[0-9]+$/) print "B " int($1) " " kind " " id " " ip " " m
    }' || true
} | sort -u > "$file.tmp"
rm -f "$chunk"

# Два запуска в одну минуту — дописываем к уже готовому файлу, а не затираем его
if [ -e "$file" ]; then sort -u "$file" "$file.tmp" -o "$file.tmp"; fi

# Пусто — файл не оставляем; иначе публикуем атомарно
if [ -s "$file.tmp" ]; then chmod 644 "$file.tmp"; mv "$file.tmp" "$file"; else rm -f "$file.tmp"; fi

# Сервер долго не забирал — храним не больше суток
find "$out" -name '*.txt' -mmin +1440 -delete
EOF

# Выдача: единственное, что может ключ главного сервера
cat > /usr/local/bin/node-ips-get <<'EOF'
#!/bin/bash
# «get» — отдать файлы, «ack имя…» — удалить забранные. Других команд нет
set -euf
out=/var/lib/node-ips/out

# Команда от сервера — словами; шаблоны (*) не раскрываем
set -- ${SSH_ORIGINAL_COMMAND:-}
case "${1:-}" in
    get)
        for f in $(cd "$out" && find . -maxdepth 1 -name '*.txt' | sort); do
            echo "## ${f#./}"
            cat "$out/${f#./}"
        done
        ;;
    ack)
        shift
        for name in "$@"; do
            if [[ "$name" =~ ^[0-9]{12}\.txt$ ]]; then rm -f "$out/$name"; fi
        done
        ;;
    *)
        echo "unknown command" >&2
        exit 1
        ;;
esac
EOF
chmod 755 /usr/local/bin/node-ips /usr/local/bin/node-ips-get

# Расписание: каждые 5 минут
echo '*/5 * * * * root /usr/local/bin/node-ips' > /etc/cron.d/node-ips
chmod 644 /etc/cron.d/node-ips

# SSH может пускать только избранных — предупредим, если nodeips не в списке
if grep -Eiq '^\s*(AllowUsers|AllowGroups)\b' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
    echo "⚠ В sshd задан AllowUsers/AllowGroups — добавьте туда $user и перезапустите ssh"
fi

# Первый прогон: запоминаем конец лога, дальше собираем только новое
/usr/local/bin/node-ips
echo "OK: сбор каждые 5 минут в $dir/out, забирает только ключ главного сервера"
