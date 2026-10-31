#!/bin/bash
# Сбор с ноды для главного сервера: пары «клиент + IP», попытки торрента, баны блокеров и
# нагрузка ноды. Нода раз в 5 минут складывает их в файл, главный сервер забирает по SSH
# ключом, который умеет только это. Сайты, которые открывают клиенты, никуда не уходят. Журнал
# Xray скрипт только читает: ротацию журнала настраивают отдельно, вместе с логом в ядре.
#
# Строки файла:
#   123456 203.0.113.10                           — пара: клиент и IP
#   T 123456 203.0.113.10 14                      — 14 попыток в TORRENT за 5 минут
#   B 1761660300 tblocker 123456 203.0.113.10 10  — бан: время (unix), источник, клиент, IP, минут
#   L mem_total=3915 mem_avail=643 cpu=16 st=1 rx=14 tx=14 conn=2417 xray_up=167000 oom=0 exit_ms=9 exit_ip=203.0.113.10 disk=41
#                                                 — нагрузка: память (МБ), CPU и steal (%), канал
#                                                   (Мбит/с), соединений на 443, сколько работает xray
#                                                   (сек), убито по памяти, проверка выхода (мс, пусто —
#                                                   нет ответа), выходной IP, диск (%)
# Источники бана: tblocker (xray-torrent-blocker), p2pban (по поведению), p2pban_extend
# (p2pban продлил бан блокера при повторах)
#
# Установка:  bash node-ips.sh            (спросит публичный ключ главного сервера)
#             NODEIPS_KEY='ssh-ed25519 AAAA…' bash node-ips.sh
# Обновление: bash node-ips.sh            (ключ уже стоит — не спрашивает)
# Удаление:   bash node-ips.sh --remove
#
# Проверку выхода (exit_ms, exit_ip) настраивать не нужно: сборщик смотрит, как выходит сам xray.
# Почти все его исходящие — к 1–2 адресам: нода промежуточная, меряем подключение к ним и
# выходной IP не пишем. Иначе — generate_204 и выходной IP через тот интерфейс, с которого xray
# открывает соединения. Xray простаивает — через маршрут по умолчанию
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

# Программы сборщика: на голом образе части может не быть
for cmd in curl ss pgrep timeout journalctl flock ip; do
    command -v "$cmd" >/dev/null || { echo "Нет $cmd — поставьте: apt install -y curl iproute2 procps coreutils util-linux"; exit 1; }
done

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

# Сборщик: новые строки лога и журналов блокеров, нагрузка ноды → файл с отметкой времени
cat > /usr/local/bin/node-ips <<'EOF'
#!/bin/bash
# Раз в 5 минут: пары «клиент + IP», попытки торрента, баны блокеров и нагрузка ноды
set -eu
export LC_ALL=C
log=/var/lib/pg-node/access.log
state=/var/lib/node-ips
out=$state/out
pos_file=$state/pos

# Нагрузка ноды одной строкой «L имя=значение…». Пустое значение — не измерили: CPU и канал
# считаются от прошлого запуска, первый после установки или перезагрузки их не знает
load_line() {
    local now mem_total mem_avail cpu='' st='' rx='' tx='' conn up oom exit_ms='' exit_ip='' disk
    local c1 c2 c3 c4 c5 c6 c7 c8 p1 p2 p3 p4 p5 p6 p7 p8 total rxb=0 txb=0 pt prx ptx d
    local pid xout='' total top src exit_if='' h p ms s r worst=0 ok=1
    now=$(date +%s)

    # Память, МБ: всего и доступно (MemAvailable — с учётом кеша, который можно отдать)
    mem_total=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
    mem_avail=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)

    # CPU и steal, % с прошлого запуска. Поля /proc/stat: user nice system idle iowait irq softirq steal
    read -r _ c1 c2 c3 c4 c5 c6 c7 c8 _ < /proc/stat
    if read -r p1 p2 p3 p4 p5 p6 p7 p8 2>/dev/null < "$state/cpu"; then
        total=$(( (c1 + c2 + c3 + c4 + c5 + c6 + c7 + c8) - (p1 + p2 + p3 + p4 + p5 + p6 + p7 + p8) ))
        if [ "$total" -gt 0 ]; then
            cpu=$(( ((c1 + c2 + c3 + c6 + c7) - (p1 + p2 + p3 + p6 + p7)) * 100 / total ))
            st=$(( (c8 - p8) * 100 / total ))
        fi
    fi
    echo "$c1 $c2 $c3 $c4 $c5 $c6 $c7 $c8" > "$state/cpu"

    # Канал, Мбит/с с прошлого запуска: сумма по физическим интерфейсам (туннели вроде warp
    # и docker не считаем — их трафик уже прошёл через физический). Счётчики обнулились — пропуск
    for d in /sys/class/net/*; do
        [ -e "$d/device" ] || continue
        rxb=$(( rxb + $(cat "$d/statistics/rx_bytes") ))
        txb=$(( txb + $(cat "$d/statistics/tx_bytes") ))
    done
    if read -r pt prx ptx 2>/dev/null < "$state/net" && [ "$now" -gt "$pt" ] && [ "$rxb" -ge "$prx" ] && [ "$txb" -ge "$ptx" ]; then
        rx=$(( (rxb - prx) * 8 / (now - pt) / 1000000 ))
        tx=$(( (txb - ptx) * 8 / (now - pt) / 1000000 ))
    fi
    echo "$now $rxb $txb" > "$state/net"

    # Открытых входящих на 443 и сколько секунд работает xray (не запущен — 0)
    conn=$(ss -Htn state established '( sport = :443 )' 2>/dev/null | wc -l)
    up=$(ps -o etimes= -C xray 2>/dev/null | sort -n | tail -n 1 | tr -d ' ')

    # Убито за нехваткой памяти с прошлого запуска: курсор помнит, где остановились
    oom=$(journalctl -k --cursor-file="$state/oom.cursor" --since "-10 min" --no-pager -q 2>/dev/null | grep -c 'Killed process' || true)

    # Как выходит сам xray: его исходящие соединения — «свой IP, куда, порт». Входящие на 443
    # и соединения внутри сервера (fallback на 127.0.0.1) не считаем
    pid=$(pgrep -xo xray || true)
    if [ -n "$pid" ]; then
        xout=$(ss -Htnp state established 2>/dev/null | awk -v p="pid=$pid," '
            index($0, p) && $3 !~ /:443$/ {
                l = $3; sub(/:[0-9]+$/, "", l); gsub(/\[|\]/, "", l)
                r = $4; port = r; sub(/.*:/, "", port); sub(/:[0-9]+$/, "", r); gsub(/\[|\]/, "", r)
                if (l !~ /^127\./ && l != "::1" && r !~ /^127\./ && r != "::1") print l, r, port
            }')
    fi
    total=$(printf '%s\n' "$xout" | grep -c . || true)

    # Почти всё (от 90% из хотя бы 50 соединений) к 1–2 адресам — нода промежуточная: её
    # клиенты выходят там. Меряем подключение к этим адресам, в exit_ms — худшее
    top=$(printf '%s\n' "$xout" | awk 'NF {print $2, $3}' | sort | uniq -c | sort -rn | head -n 2)
    if [ "$total" -ge 50 ] && [ $(( $(printf '%s\n' "$top" | awk '{s += $1} END {print s + 0}') * 100 )) -ge $(( total * 90 )) ]; then
        while read -r _ h p; do
            [[ "$h" =~ ^[0-9a-fA-F.:]+$ && "$p" =~ ^[0-9]+$ ]] || { ok=0; continue; }
            s=$(date +%s%N)
            if timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$h" "$p" 2>/dev/null; then
                ms=$(( ($(date +%s%N) - s) / 1000000 ))
                if [ "$ms" -gt "$worst" ]; then worst=$ms; fi
            else
                ok=0
            fi
        done <<< "$top"
    else

        # Нода выходит сама: проверяем через тот интерфейс, с которого xray открывает больше всего
        # соединений (у ноды с подменой адреса это не маршрут по умолчанию). Простаивает — по умолчанию
        src=$(printf '%s\n' "$xout" | awk 'NF {print $1}' | sort | uniq -c | sort -rn | awk 'NR == 1 {print $2}')
        if [ -n "$src" ]; then exit_if=$(ip -o addr show 2>/dev/null | awk -v ip="$src" '{split($4, a, "/"); if (a[1] == ip) {print $2; exit}}'); fi
        r=$(curl -4 -s ${exit_if:+--interface "$exit_if"} --max-time 5 -o /dev/null -w '%{http_code} %{time_total}' https://www.google.com/generate_204 2>/dev/null || true)
        if [ -n "$r" ] && [ "${r%% *}" != 000 ]; then worst=$(awk -v t="${r##* }" 'BEGIN {printf "%d", t * 1000}'); else ok=0; fi

        # С какого IP нода выходит в интернет: хостинг может подменить его на свой
        exit_ip=$(curl -4 -s ${exit_if:+--interface "$exit_if"} --max-time 5 https://api.ipify.org 2>/dev/null || true)
        [[ "$exit_ip" =~ ^[0-9a-fA-F.:]+$ ]] || exit_ip=''
    fi
    if [ "$ok" = 1 ]; then exit_ms=$worst; fi

    # Занято на диске, %
    disk=$(df -P / | awk 'NR == 2 {sub(/%/, "", $5); print $5}')

    echo "L mem_total=$mem_total mem_avail=$mem_avail cpu=$cpu st=$st rx=$rx tx=$tx conn=$conn xray_up=${up:-0} oom=$oom exit_ms=$exit_ms exit_ip=$exit_ip disk=$disk"
}

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

    # Нагрузка ноды: сбой одной проверки не должен оставить ноду без пар
    load_line || true
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
