#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# СЕЛФСТИЛ: сайт-прикрытие для REALITY на 127.0.0.1:8443
#
# Один скрипт на все ноды, можно запускать на всех одновременно: ноды выстраиваются
# в очередь через замок в DNS Cloudflare и выпускают сертификат по одной.
#
# Домен: переменная ZONE → вопрос при запуске вручную (Enter — текущий из .env) → /root/caddy/.env.
#        Из cron вопроса нет: домен из .env. Сертификат на *.домен, домен — зона в Cloudflare,
#        токену нужен доступ к ней. Без вопроса: ZONE=example.org bash /root/selfsteal.sh — запомнится в .env.
#        Смена домена без простоя: пока выпускается новый сертификат, Caddy отвечает старым
#        (REALITY пускает клиентов, пока dest отвечает на рукопожатие). Не вышло — нода
#        остаётся на старом домене, ZONE в .env не меняется, запуск можно повторить.
# Центр сертификации: Google Trust Services, если заданы его ключи EAB (GTS_KID, GTS_HMAC),
#        иначе ZeroSSL (ZEROSSL_KID, ZEROSSL_HMAC). При первом запуске вручную скрипт сначала
#        предлагает ключи Google с подсказкой, как их получить; Enter — пропустить и взять ZeroSSL.
#        Ключ Google одноразовый: на новую ноду — новый ключ, продления идут без него.
# Ключи: переменные окружения CF_API_TOKEN и ключи центра → /root/caddy/.env → вопрос.
# Сайт: /root/caddy/site/index.html — одна из стандартных страниц веб-серверов, выбор по IP ноды,
#       постоянный. Нет файла — вопрос: шаблон по умолчанию или свой HTML до строки END.
#       Сменить страницу: rm /root/caddy/site/index.html и запустить снова.
# Сертификат: wildcard *.домен, проверка домена через DNS Cloudflare.
#             Завис выпуск — скрипт сам перечитывает конфиг Caddy (без обрыва соединений), до трёх попыток.
# В конце самопроверка: заголовки, чужое имя и путь, запрос без имени, порт 8443 закрыт снаружи.
#             OK пишется, только если всё чисто
#
# Запуск:  bash /root/selfsteal.sh           установить или починить (сертификат из тома сохраняется)
#          bash /root/selfsteal.sh --reset   то же, но сертификат и аккаунт центра сертификации с нуля
#          bash /root/selfsteal.sh --check   проверка для cron: всё живо и сертификату больше 21 дня —
#                                            ничего не делает, иначе чинит как обычный запуск
# При каждом запуске скрипт сам ставит ежедневную проверку в cron (лог /var/log/selfsteal.log).
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

lock_ttl=1200
mode=${1:-}
ip=$(hostname -I | awk '{print $1}')

# Cron вызывает /root/selfsteal.sh — кладём туда копию, если запустили из другого места
self=$(readlink -f "$0" 2>/dev/null || true)
[ -f "$self" ] && [ "$self" != /root/selfsteal.sh ] && cp "$self" /root/selfsteal.sh
mkdir -p /root/caddy/site && cd /root/caddy
touch .env && chmod 600 .env

# Записать значение в .env: заменить строку или добавить
set_env() { grep -q "^$1=" .env && sed -i "s|^$1=.*|$1=$2|" .env || echo "$1=$2" >> .env; }

# Домен: переменная ZONE → вопрос (при запуске вручную, Enter — текущий из .env) → .env.
# Из cron и в фоне не спрашиваем: там берём из .env
old_zone=$(grep -s '^ZONE=' .env | cut -d= -f2- || true)
zone_name=${ZONE:-}
if [ -z "$zone_name" ] && [ -t 0 ] && [ "$mode" != --check ]; then
    while [ -z "$zone_name" ]; do
        read -rp "Домен для сертификата (зона в Cloudflare)${old_zone:+ [$old_zone]}: " zone_name
        zone_name=${zone_name:-$old_zone}
    done
fi
zone_name=${zone_name:-$old_zone}
[ -n "$zone_name" ] || { echo "Не задан домен: запустите вручную или ZONE=example.org bash /root/selfsteal.sh"; exit 1; }
lock_name="_selfsteal-lock.$zone_name"

# Смена домена на работающей ноде: Caddy уже отдаёт действующий сертификат старого домена.
# Тогда до выпуска нового держим оба, по умолчанию — старый, а ZONE в .env меняем только после успеха
switching=''
if [ -n "$old_zone" ] && [ "$old_zone" != "$zone_name" ] && [ "$mode" != --reset ] \
    && echo | timeout 10 openssl s_client -connect 127.0.0.1:8443 -servername "www.$old_zone" 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | grep -qF "*.$old_zone"; then
    switching=$old_zone
    echo "Смена домена $old_zone → $zone_name: до нового сертификата нода работает на старом"
else
    set_env ZONE "$zone_name"
fi

# Имена для проверок: своё — любое под звёздочку сертификата, чужое — заведомо не наше
own_host="www.$zone_name"
foreign_host=example.com

# Нода в порядке: страница отвечает на 8443, на чужое имя тоже есть ответ TLS (см. fallback_sni),
# сертификат именно на *.домен (при смене домена старый не считается) и действует ещё больше 21 дня
cert_ok() {
    curl -sk -m 10 -o /dev/null --resolve "$own_host:8443:127.0.0.1" "https://$own_host:8443" || return 1
    echo | timeout 10 openssl s_client -connect 127.0.0.1:8443 -servername "$foreign_host" 2>/dev/null \
        | grep -c 'BEGIN CERTIFICATE' >/dev/null || return 1
    echo | timeout 10 openssl s_client -connect 127.0.0.1:8443 -servername "$own_host" 2>/dev/null \
        | openssl x509 -noout -subject -checkend $((21 * 86400)) 2>/dev/null | grep -qF "*.$zone_name"
}
cert_end() {
    echo | timeout 10 openssl s_client -connect 127.0.0.1:8443 -servername "$own_host" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2
}

# Кто выдал сертификат, который сейчас отдаёт Caddy: Google, ZeroSSL или пусто
cert_issuer() {
    echo | timeout 10 openssl s_client -connect 127.0.0.1:8443 -servername "$own_host" 2>/dev/null \
        | openssl x509 -noout -issuer 2>/dev/null | grep -oE 'Google Trust Services|ZeroSSL' | head -1 || true
}

# Проверка из cron: всё в порядке — выходим, ничего не трогая
if [ "$mode" = --check ]; then
    if cert_ok; then
        echo "$(date '+%F %T') OK $ip, сертификат от $(cert_issuer) до $(cert_end)"
        exit 0
    fi
    echo "$(date '+%F %T') $ip: страница не отвечает или сертификат скоро истечёт — чиним"
fi

# ─── Ключи ───────────────────────────────────────────────────────────────────
key() {
    local value="${!1:-}"
    [ -n "$value" ] || value=$(grep -s "^$1=" .env | cut -d= -f2- || true)
    [ -n "$value" ] || { read -rsp "$2: " value; echo; }
    [ -n "$value" ] || { echo "Нет значения $1"; exit 1; }
    grep -q "^$1=" .env && sed -i "s|^$1=.*|$1=$value|" .env || echo "$1=$value" >> .env
}
key CF_API_TOKEN 'Токен Cloudflare'

# Центр сертификации: Google, если его ключи уже есть (окружение или .env). Нет — при запуске
# вручную сначала предлагаем их ввести с подсказкой; Enter — пропустить, тогда ZeroSSL
gts_kid=${GTS_KID:-$(grep -s '^GTS_KID=' .env | cut -d= -f2- || true)}
if [ -z "$gts_kid" ] && [ -t 0 ] && [ "$mode" != --check ]; then
    cat <<'HINT'

Сертификат можно выпустить у Google Trust Services. Ключ одноразовый: на каждую новую ноду — свой.
  1. https://console.cloud.google.com/welcome — открыть Cloud Shell (значок терминала справа вверху)
  2. gcloud services enable publicca.googleapis.com
  3. gcloud publicca external-account-keys create
     → keyId и b64MacKey из ответа вставить ниже
Нет ключей — нажмите Enter, сертификат выпустит ZeroSSL.

HINT
    read -rp "Google keyId: " gts_kid
    if [ -n "$gts_kid" ]; then
        read -rsp "Google b64MacKey: " gts_hmac; echo
        [ -n "$gts_hmac" ] || { echo "Нет b64MacKey"; exit 1; }
        set_env GTS_KID "$gts_kid"
        set_env GTS_HMAC "$gts_hmac"
    fi
fi
if [ -n "$gts_kid" ]; then
    key GTS_KID 'Google keyId'
    key GTS_HMAC 'Google b64MacKey'
    ca_name='Google Trust Services'
    ca_kid_var=GTS_KID
else
    key ZEROSSL_KID 'ZeroSSL EAB kid'
    key ZEROSSL_HMAC 'ZeroSSL EAB hmac'
    ca_name='ZeroSSL'
    ca_kid_var=ZEROSSL_KID
fi
set -a; . ./.env; set +a

# Выпускающие центры для Caddy: основной первым, второй — если его ключи тоже есть.
# Оба сразу нужны по двум причинам: Caddy находит в хранилище сертификат, только если выпустивший его
# центр есть в конфиге (сменили центр — старый сертификат продолжает работать, пока выпускается новый),
# и не выдал основной — Caddy сам пробует второй
acme_issuer() {
    cat <<CADDY
        issuer acme $1 {
            eab {env.$2} {env.$3}
            dns cloudflare {env.CF_API_TOKEN}
            propagation_delay 30s
            propagation_timeout -1
        }
CADDY
}
google_issuer=''
zerossl_issuer=''
[ -n "${GTS_KID:-}" ] && [ -n "${GTS_HMAC:-}" ] \
    && google_issuer=$(acme_issuer https://dv.acme-v02.api.pki.goog/directory GTS_KID GTS_HMAC)
[ -n "${ZEROSSL_KID:-}" ] && [ -n "${ZEROSSL_HMAC:-}" ] \
    && zerossl_issuer=$(acme_issuer https://acme.zerossl.com/v2/DV90 ZEROSSL_KID ZEROSSL_HMAC)
if [ "$ca_kid_var" = GTS_KID ]; then
    issuers=$google_issuer${zerossl_issuer:+$'\n'$zerossl_issuer}
else
    issuers=$zerossl_issuer${google_issuer:+$'\n'$google_issuer}
fi

# ─── Сайт-прикрытие ──────────────────────────────────────────────────────────
# Семь стандартных страниц веб-серверов: у каждой свой заголовок Server, у 403 — свой код ответа.
# Такие страницы отдают миллионы серверов, по ним нельзя собрать список наших нод
templates=(apache-ubuntu apache-debian caddy iis nginx-403 tomcat coming-soon)
server_header() {
    case "$1" in
        apache-ubuntu) echo 'Apache/2.4.58 (Ubuntu)' ;;
        apache-debian) echo 'Apache/2.4.62 (Debian)' ;;
        caddy)         echo 'Caddy' ;;
        iis)           echo 'Microsoft-IIS/10.0' ;;
        nginx-403)     echo 'nginx/1.24.0 (Ubuntu)' ;;
        tomcat)        echo '' ;;
        coming-soon)   echo 'Apache' ;;
    esac
}

write_template() {
    case "$1" in
apache-ubuntu) cat > site/index.html <<'HTML'
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
  <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
    <title>Apache2 Ubuntu Default Page: It works</title>
    <style type="text/css" media="screen">
  * { margin: 0px 0px 0px 0px; padding: 0px 0px 0px 0px; }
  body, html { padding: 3px 3px 3px 3px; background-color: #D8DBE2; font-family: Verdana, sans-serif; font-size: 11pt; text-align: center; }
  div.main_page { position: relative; display: block; width: 800px; margin-bottom: 3px; margin-left: auto; margin-right: auto; padding: 0px 0px 0px 0px; border-width: 2px; border-color: #212738; border-style: solid; background-color: #FFFFFF; text-align: center; }
  div.page_header { height: 99px; width: 100%; background-color: #F5F6F7; }
  div.page_header span { margin: 15px 0px 0px 50px; font-size: 180%; font-weight: bold; }
  div.content_section { margin: 3px 3px 3px 3px; background-color: #FFFFFF; text-align: left; }
  div.content_section_text { padding: 4px 8px 4px 8px; color: #000000; font-size: 100%; }
  div.content_section_text pre { margin: 8px 0px 8px 0px; padding: 8px 8px 8px 8px; border-width: 1px; border-style: dotted; border-color: #000000; background-color: #F5F6F7; font-style: italic; }
  div.content_section_text p { margin-bottom: 6px; }
  div.content_section_text ul, div.content_section_text li { padding: 4px 8px 4px 16px; }
  div.section_header { padding: 3px 6px 3px 6px; background-color: #8E9CB2; color: #FFFFFF; font-weight: bold; font-size: 112%; text-align: center; }
  div.section_header_red { background-color: #CD214F; }
  .floating_element { position: relative; float: left; }
  div.content_section_text a { text-decoration: none; font-weight: bold; }
  div.content_section_text a:link, div.content_section_text a:visited, div.content_section_text a:active { background-color: #DCDFE6; color: #000000; }
  div.content_section_text a:hover { background-color: #000000; color: #DCDFE6; }
    </style>
  </head>
  <body>
    <div class="main_page">
      <div class="page_header floating_element">
        <span class="floating_element">Apache2 Ubuntu Default Page</span>
      </div>
      <div class="content_section floating_element">
        <div class="section_header section_header_red">
          <div id="about"></div>
          It works!
        </div>
        <div class="content_section_text">
          <p>This is the default welcome page used to test the correct operation of the Apache2 server after installation on Ubuntu systems. It is based on the equivalent page on Debian, from which the Ubuntu Apache packaging is derived. If you can read this page, it means that the Apache HTTP server installed at this site is working properly. You should <b>replace this file</b> (located at <tt>/var/www/html/index.html</tt>) before continuing to operate your HTTP server.</p>
          <p>If you are a normal user of this web site and don't know what this page is about, this probably means that the site is currently unavailable due to maintenance. If the problem persists, please contact the site's administrator.</p>
        </div>
        <div class="section_header">
          <div id="changes"></div>
          Configuration Overview
        </div>
        <div class="content_section_text">
          <p>Ubuntu's Apache2 default configuration is different from the upstream default configuration, and split into several files optimized for interaction with Ubuntu tools. The configuration system is <b>fully documented in /usr/share/doc/apache2/README.Debian.gz</b>. Refer to this for the full documentation. Documentation for the web server itself can be found by accessing the <a href="/manual">manual</a> if the <tt>apache2-doc</tt> package was installed on this server.</p>
          <p>The configuration layout for an Apache2 web server installation on Ubuntu systems is as follows:</p>
          <pre>
/etc/apache2/
|-- apache2.conf
|       `--  ports.conf
|-- mods-enabled
|       |-- *.load
|       `-- *.conf
|-- conf-enabled
|       `-- *.conf
|-- sites-enabled
|       `-- *.conf
          </pre>
          <ul>
            <li><tt>apache2.conf</tt> is the main configuration file. It puts the pieces together by including all remaining configuration files when starting up the web server.</li>
            <li><tt>ports.conf</tt> is always included from the main configuration file. It is used to determine the listening ports for incoming connections, and this file can be customized anytime.</li>
            <li>Configuration files in the <tt>mods-enabled/</tt>, <tt>conf-enabled/</tt> and <tt>sites-enabled/</tt> directories contain particular configuration snippets which manage modules, global configuration fragments, or virtual host configurations, respectively.</li>
            <li>They are activated by symlinking available configuration files from their respective *-available/ counterparts. These should be managed by using our helpers <tt>a2enmod</tt>, <tt>a2dismod</tt>, <tt>a2ensite</tt>, <tt>a2dissite</tt>, and <tt>a2enconf</tt>, <tt>a2disconf</tt>. See their respective man pages for detailed information.</li>
            <li>The binary is called apache2. Due to the use of environment variables, in the default configuration, apache2 needs to be started/stopped with <tt>/etc/init.d/apache2</tt> or <tt>apache2ctl</tt>. <b>Calling <tt>/usr/bin/apache2</tt> directly will not work</b> with the default configuration.</li>
          </ul>
        </div>
        <div class="section_header">
          <div id="docroot"></div>
          Document Roots
        </div>
        <div class="content_section_text">
          <p>By default, Ubuntu does not allow access through the web browser to <em>any</em> file apart of those located in <tt>/var/www</tt>, <a href="http://httpd.apache.org/docs/2.4/mod/mod_userdir.html" rel="nofollow">public_html</a> directories (when enabled) and <tt>/usr/share</tt> (for web applications). If your site is using a web document root located elsewhere (such as in <tt>/srv</tt>) you may need to whitelist your document root directory in <tt>/etc/apache2/apache2.conf</tt>.</p>
          <p>The default Ubuntu document root is <tt>/var/www/html</tt>. You can make your own virtual hosts under /var/www. This is different to previous releases which provides better security out of the box.</p>
        </div>
        <div class="section_header">
          <div id="bugs"></div>
          Reporting Problems
        </div>
        <div class="content_section_text">
          <p>Please use the <tt>ubuntu-bug</tt> tool to report bugs in the Apache2 package with Ubuntu. However, check <a href="https://bugs.launchpad.net/ubuntu/+source/apache2" rel="nofollow">existing bug reports</a> before reporting a new bug.</p>
          <p>Please report bugs specific to modules (such as PHP and others) to respective packages, not to the web server itself.</p>
        </div>
      </div>
    </div>
  </body>
</html>
HTML
;;
apache-debian) cat > site/index.html <<'HTML'
<html><body><h1>It works!</h1>
<p>This is the default web page for this server.</p>
<p>The web server software is running but no content has been added, yet.</p>
</body></html>
HTML
;;
caddy) cat > site/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
	<title>Caddy works!</title>
	<meta charset="utf-8">
	<meta name="viewport" content="width=device-width, initial-scale=1">
	<style>
		* { box-sizing: border-box; }
		body { padding: 0; margin: 0; background: #fff; color: #333; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
		header { background: #22a7f0; color: #fff; padding: 40px 20px; text-align: center; }
		header h1 { margin: 0; font-size: 2em; font-weight: 600; }
		header p { margin: 10px 0 0; opacity: .9; }
		main { max-width: 760px; margin: 40px auto; padding: 0 20px; line-height: 1.6; }
		code { background: #f3f3f3; padding: 2px 6px; border-radius: 3px; }
		ul { padding-left: 20px; }
		footer { text-align: center; color: #999; font-size: .9em; padding: 30px; }
	</style>
</head>
<body>
	<header>
		<h1>Congratulations!</h1>
		<p>Your web server is working. Now make it work for you. 😉</p>
	</header>
	<main>
		<p>If you see this page, Caddy is serving its default site and no content has been configured yet.</p>
		<p>To serve your own site:</p>
		<ul>
			<li>Put your files in the site root directory</li>
			<li>Edit the <code>Caddyfile</code> and set <code>root</code> and <code>file_server</code></li>
			<li>Reload the configuration with <code>caddy reload</code></li>
		</ul>
		<p>Documentation and community help are available at <a href="https://caddyserver.com/docs/">caddyserver.com/docs</a>.</p>
	</main>
	<footer>Caddy &mdash; a web server for the modern internet.</footer>
</body>
</html>
HTML
;;
iis) cat > site/index.html <<'HTML'
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
<title>IIS Windows Server</title>
<style type="text/css">
<!--
body { color:#000000; background-color:#0072C6; margin:0; }
#container { margin-left:auto; margin-right:auto; text-align:center; }
#banner { margin-top:120px; font-family:"Segoe UI",Arial,sans-serif; color:#ffffff; font-size:64px; font-weight:200; letter-spacing:-1px; }
#sub { font-family:"Segoe UI",Arial,sans-serif; color:#ffffff; font-size:22px; font-weight:300; margin-top:8px; }
#logo { margin-top:60px; font-family:"Segoe UI",Arial,sans-serif; color:#ffffff; font-size:16px; opacity:.8; }
-->
</style>
</head>
<body>
<div id="container">
<div id="banner">Internet Information Services</div>
<div id="sub">Welcome&nbsp; Bienvenue&nbsp; Willkommen&nbsp; Bienvenido&nbsp; 欢迎&nbsp; Добро пожаловать</div>
<div id="logo">Microsoft &middot; Windows Server</div>
</div>
</body>
</html>
HTML
;;
nginx-403) cat > site/index.html <<'HTML'
<html>
<head><title>403 Forbidden</title></head>
<body>
<center><h1>403 Forbidden</h1></center>
<hr><center>nginx/1.24.0 (Ubuntu)</center>
</body>
</html>
HTML
;;
tomcat) cat > site/index.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
    <head>
        <meta charset="UTF-8" />
        <title>Apache Tomcat/10.1.30</title>
        <style type="text/css">
            body { font-family: Tahoma, Arial, sans-serif; color: black; background-color: white; margin: 0; }
            #header { background-color: #D2A41C; padding: 16px 24px; color: #fff; }
            #header h1 { margin: 0; font-size: 28px; font-weight: normal; }
            #header .subtitle { font-size: 14px; opacity: .9; margin-top: 4px; }
            #content { max-width: 960px; margin: 0 auto; padding: 24px; }
            .row { display: flex; gap: 24px; flex-wrap: wrap; }
            .col { flex: 1 1 260px; }
            h3 { font-size: 16px; margin: 20px 0 8px; color: #525D76; border-bottom: 1px solid #D2A41C; padding-bottom: 4px; }
            p, li { font-size: 14px; line-height: 1.5; }
            a { color: #525D76; }
            .success { background: #ECF4E8; border: 1px solid #C4DFB4; padding: 12px 16px; margin-bottom: 20px; font-size: 14px; }
            #footer { background: #D2A41C; color: #fff; text-align: center; padding: 10px; font-size: 12px; margin-top: 40px; }
        </style>
    </head>
    <body>
        <div id="header">
            <h1>Apache Tomcat<span style="font-size: 18px;">/10.1.30</span></h1>
            <div class="subtitle">Home &nbsp;|&nbsp; Documentation &nbsp;|&nbsp; Configuration &nbsp;|&nbsp; Examples &nbsp;|&nbsp; Wiki &nbsp;|&nbsp; Mailing Lists</div>
        </div>
        <div id="content">
            <div class="success"><strong>If you're seeing this, you've successfully installed Tomcat. Congratulations!</strong></div>
            <div class="row">
                <div class="col">
                    <h3>Recommended Reading:</h3>
                    <ul>
                        <li><a href="#">Security Considerations How-To</a></li>
                        <li><a href="#">Manager Application How-To</a></li>
                        <li><a href="#">Clustering/Session Replication How-To</a></li>
                    </ul>
                </div>
                <div class="col">
                    <h3>Developer Quick Start</h3>
                    <ul>
                        <li>Tomcat Setup</li>
                        <li>First Web Application</li>
                        <li>Realms &amp; AAA</li>
                        <li>JDBC DataSources</li>
                    </ul>
                </div>
                <div class="col">
                    <h3>Managing Tomcat</h3>
                    <p>For security, access to the <strong>manager webapp</strong> is restricted. Users are defined in:</p>
                    <p><code>$CATALINA_HOME/conf/tomcat-users.xml</code></p>
                    <p>In Tomcat 10.1 access to the manager application is split between different users.</p>
                </div>
            </div>
            <div class="row">
                <div class="col">
                    <h3>Documentation</h3>
                    <p><a href="#">Tomcat 10.1 Documentation</a></p>
                    <p><a href="#">Tomcat 10.1 Configuration</a></p>
                    <p><a href="#">Tomcat Wiki</a></p>
                    <p>Find additional important configuration information in: <code>$CATALINA_HOME/RUNNING.txt</code></p>
                </div>
                <div class="col">
                    <h3>Getting Help</h3>
                    <p><strong>FAQ and Mailing Lists</strong></p>
                    <p>The following mailing lists are available: tomcat-announce, tomcat-users, taglibs-user, tomcat-dev.</p>
                </div>
            </div>
        </div>
        <div id="footer">Copyright &copy;1999-2024 Apache Software Foundation. All Rights Reserved</div>
    </body>
</html>
HTML
;;
coming-soon) cat > site/index.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Website Coming Soon</title>
<style>
  html,body{height:100%;margin:0}
  body{display:flex;align-items:center;justify-content:center;background:linear-gradient(135deg,#2b5876 0%,#4e4376 100%);font-family:"Helvetica Neue",Helvetica,Arial,sans-serif;color:#fff;text-align:center}
  .wrap{max-width:560px;padding:40px}
  .logo{width:72px;height:72px;margin:0 auto 24px;border:3px solid rgba(255,255,255,.7);border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:30px}
  h1{font-size:32px;font-weight:300;margin:0 0 12px;letter-spacing:.02em}
  p{font-size:16px;line-height:1.6;opacity:.85;margin:0 0 10px}
  .note{margin-top:28px;font-size:13px;opacity:.6}
</style>
</head>
<body>
<div class="wrap">
  <div class="logo">&#9881;</div>
  <h1>Website Coming Soon</h1>
  <p>This domain has been registered and hosting is active, but the website has not been published yet.</p>
  <p>If you are the owner of this domain, upload your website files to the document root to replace this page.</p>
  <div class="note">Default hosting page &middot; Powered by shared web hosting</div>
</div>
</body>
</html>
HTML
;;
    esac
}

# Шаблон выбирается по последнему октету IP: у ноды он всегда один и тот же
template=${templates[$(( ${ip##*.} % ${#templates[@]} ))]}
if [ -s site/index.html ]; then
    template=$(cat site/.template 2>/dev/null || echo custom)
else
    read -rp "Сайт-прикрытие: шаблон по умолчанию ($template)? [Y/n] " answer
    if [[ "${answer:-y}" =~ ^[Nn] ]]; then
        echo 'Вставьте HTML целиком, затем на отдельной строке напишите END'
        : > site/index.html
        while IFS= read -r line; do
            [ "$line" = END ] && break
            printf '%s\n' "$line" >> site/index.html
        done
        template=custom
    else
        write_template "$template"
    fi
    echo "$template" > site/.template
fi
echo "Страница-прикрытие: $template"

# ─── Конфиги Caddy ───────────────────────────────────────────────────────────
cat > compose.yaml <<'YAML'
services:
  caddy:
    image: ghcr.io/caddybuilds/caddy-cloudflare:latest
    restart: unless-stopped
    network_mode: host
    environment:
      CF_API_TOKEN: ${CF_API_TOKEN}
      ZEROSSL_KID: ${ZEROSSL_KID:-}
      ZEROSSL_HMAC: ${ZEROSSL_HMAC:-}
      GTS_KID: ${GTS_KID:-}
      GTS_HMAC: ${GTS_HMAC:-}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./site:/srv:ro
      - data:/data
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: '2'
volumes:
  data:
YAML

# Заголовок Server — под выбранную страницу, у 403 ещё и код ответа.
# Свою проверку TXT Caddy не делает (propagation_timeout -1): на нодах, где DNS режут или он
# тормозит, она зависала навсегда. Cloudflare публикует запись за секунды, 30 секунд ожидания с запасом
server=$(server_header "$template")

# Значение в кавычках: без них «nginx/1.24.0 (Ubuntu)» Caddy читает как «найти и заменить» и заголовок не ставит.
# Ставим или удаляем — что-то одно: удаление у Caddy срабатывает после установки и стёрло бы значение
header_line='header -Server'
[ -n "$server" ] && header_line="header Server \"$server\""
# Блок только многострочный: { status 403 } в одну строку Caddy не принимает и падает на старте
files='file_server'
[ "$template" = nginx-403 ] && files=$'file_server {\n        status 403\n    }'
# fallback_sni: на чужое имя (например, старый sni клиентов, пока он в serverNames) Caddy отвечает нашим сертификатом.
# Без этого он рвёт рукопожатие, а REALITY пускает клиента, только если dest прислал ServerHello —
# клиенты со старым sni после переключения dest перестали бы подключаться.
# Имя — ровно как в сертификате, со звёздочкой: Caddy ищет его буквально, на поддомен сертификат не находился.
# default_bind: слушаем только 127.0.0.1 — снаружи 8443 закрыт, к Caddy ходит только Xray этой ноды.
# protocols h1 h2: без HTTP/3, иначе Caddy слушает UDP и в каждом ответе пишет Alt-Svc h3=":8443" — выдаёт порт.
# default_sni: запрос вовсе без имени (сканер по голому IP) тоже получает наш сертификат.
# Сайт отвечает на любое имя (https://) и на любой путь (try_files): иначе на чужое имя или путь
# Caddy отдавал пустую страницу с «Server: Caddy» — так nginx и Apache себя не ведут.
# email: Google не регистрирует ACME-аккаунт без контакта (ZeroSSL — да), берём admin@ домена ноды.
# Аргументы: главный домен (default_sni, fallback_sni, https://), затем дополнительные — при смене домена
write_caddyfile() {
    local main=$1 zone sites
    shift
    {
        cat <<CADDY
{
    email admin@$zone_name
    auto_https disable_redirects
    https_port 8443
    default_bind 127.0.0.1
    default_sni *.$main
    fallback_sni *.$main
    servers {
        protocols h1 h2
    }
}
CADDY
        for zone in "$main" "$@"; do
            sites="*.$zone"
            [ "$zone" = "$main" ] && sites="*.$zone, https://"
            cat <<CADDY

$sites {
    tls {
$issuers
    }
    $header_line
    root * /srv
    try_files {path} /index.html
    $files
}
CADDY
        done
    } > Caddyfile.new
}

# Проверяем новый Caddyfile и только потом ставим вместо рабочего: с ошибкой в конфиге Caddy
# падает по кругу, а после переключения dest на него без Caddy не пускает и VPN.
# Пишем поверх, а не через mv: файл смонтирован в контейнер, после mv Caddy видел бы старый
install_caddyfile() {
    local out
    if ! out=$(docker run --rm -v "$PWD/Caddyfile.new:/etc/caddy/Caddyfile:ro" ghcr.io/caddybuilds/caddy-cloudflare:latest \
            caddy adapt --config /etc/caddy/Caddyfile 2>&1 >/dev/null); then
        echo "ОШИБКА $ip: Caddy не принял новый Caddyfile, рабочий не тронут:"
        echo "$out" | tail -3
        exit 1
    fi
    cat Caddyfile.new > Caddyfile && rm -f Caddyfile.new
}

# Перечитать конфиг без перезапуска контейнера: соединения не рвутся
caddy_reload() { docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --force >/dev/null 2>&1; }

# При смене домена главным пока остаётся старый, новый — дополнительным
if [ -n "$switching" ]; then
    write_caddyfile "$switching" "$zone_name"
else
    write_caddyfile "$zone_name"
fi
install_caddyfile

# ─── Cloudflare API: зона и замок ────────────────────────────────────────────
cf() { curl -s -m 20 -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json' "$@"; }
zone_id=$(cf "https://api.cloudflare.com/client/v4/zones?name=$zone_name" | grep -o '"id":"[a-f0-9]\{32\}"' | head -1 | cut -d'"' -f4)
[ -n "$zone_id" ] || { echo "Cloudflare: зона $zone_name не найдена — проверьте токен"; exit 1; }
api="https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records"

# Записи TXT по имени: строки «id содержимое» (кавычки, которыми Cloudflare обрамляет TXT, убираем)
records() {
    cf "$api?type=TXT&name=$1&per_page=100" \
    | grep -oE '"id":"[a-f0-9]{32}","name":"[^"]*","type":"TXT","content":"(\\.|[^"\\])*"' \
    | sed -E 's/"id":"([^"]+)".*"content":"(.*)"$/\1 \2/; s/\\"//g' || true
}
delete() { cf -X DELETE "$api/$1" >/dev/null; }

lock_id=''
release() { [ -n "$lock_id" ] && delete "$lock_id" && echo 'Замок снят' || true; }
trap release EXIT

# Замок: сертификат в один момент времени выпускает одна нода. Замок старше 20 минут считаем брошенным,
# свой — тоже: он остался от прерванного или неудачного запуска этой же ноды, ждать его незачем
echo "Нода $ip: становимся в очередь на выпуск сертификата"
while :; do
    taken=''
    while read -r id content; do
        [ -n "$id" ] || continue
        owner=${content%%:*}; stamp=${content##*:}
        if [ "$owner" = "$ip" ] || [ $(( $(date +%s) - stamp )) -gt $lock_ttl ]; then delete "$id"; else taken="$owner"; fi
    done <<< "$(records "$lock_name")"
    if [ -n "$taken" ]; then echo "Домен занят нодой $taken, ждём..."; sleep 20; continue; fi

    sleep $((RANDOM % 10))
    cf -X POST "$api" --data "{\"type\":\"TXT\",\"name\":\"$lock_name\",\"content\":\"$ip:$(date +%s)\",\"ttl\":60}" >/dev/null
    sleep 3

    # Перечитываем: замков больше одного или первый не наш — проиграли гонку, снимаем свой и ждём
    all=$(records "$lock_name")
    if [ "$(echo "$all" | grep -c .)" -eq 1 ] && [[ "$all" == *" $ip:"* ]]; then
        lock_id=${all%% *}; break
    fi
    echo "$all" | grep " $ip:" | cut -d' ' -f1 | while read -r id; do [ -n "$id" ] && delete "$id"; done
    sleep $((RANDOM % 20 + 5))
done
echo 'Замок наш'

# Под замком чужих выпусков нет: все TXT _acme-challenge — брошенные, убираем
clean_challenges() {
    records "_acme-challenge.$zone_name" | cut -d' ' -f1 | while read -r id; do [ -n "$id" ] && delete "$id"; done
}
clean_challenges

# ─── Старт Caddy ─────────────────────────────────────────────────────────────
# Обычный запуск сохраняет том: действующий сертификат подхватится без нового выпуска.
# Caddy уже работает и видит ключи нужного центра — только перечитываем конфиг. Иначе (первый запуск,
# --reset, смена центра: новые ключи попадают в контейнер только при пересоздании) поднимаем контейнер
caddy_env_ok() {
    local var
    for var in GTS_KID GTS_HMAC ZEROSSL_KID ZEROSSL_HMAC; do
        [ "$(docker compose exec -T caddy printenv "$var" 2>/dev/null | tr -d '\r')" = "${!var:-}" ] || return 1
    done
}
if [ "$mode" = --reset ]; then
    docker compose down -v >/dev/null 2>&1 || true
fi
if [ "$mode" != --reset ] && docker compose ps --status running --services 2>/dev/null | grep -qx caddy \
    && caddy_env_ok && caddy_reload; then
    echo "Caddy перечитал конфиг без перезапуска (основной центр — $ca_name), проверяем сертификат..."
else
    docker compose up -d --force-recreate >/dev/null
    echo "Caddy запущен (основной центр — $ca_name), ждём сертификат..."
fi

# Действующий сертификат от другого центра Caddy не перевыпускает до продления. Выбрали центр —
# предлагаем перейти сразу: удаляем сертификат другого центра для этого домена, Caddy выпускает у
# основного. Пока выпускается (обычно 1–2 минуты), новые клиенты к ноде не подключаются; основной
# не выдал — Caddy сам берёт второй центр
if [ -z "$switching" ] && [ -t 0 ] && [ "$mode" != --check ]; then
    sleep 3
    current=$(cert_issuer)
    if [ -n "$current" ] && [ "$current" != "$ca_name" ]; then
        echo "Сейчас сертификат от $current, действует до $(cert_end)."
        read -rp "Перевыпустить у $ca_name сейчас? Нода 1–2 минуты не будет принимать новых клиентов [y/N] " answer
        if [[ "${answer:-n}" =~ ^[YyДд] ]]; then
            case $current in
                ZeroSSL) other_dir=acme.zerossl.com-v2-dv90 ;;
                *)       other_dir=dv.acme-v02.api.pki.goog-directory ;;
            esac
            # Перезапуск, а не reload: сертификат лежит и в памяти Caddy, после reload он отдавался бы дальше
            docker compose exec -T caddy rm -rf "/data/caddy/certificates/$other_dir/wildcard_.$zone_name"
            docker compose restart >/dev/null
            echo "Сертификат от $current удалён, ждём новый от $ca_name..."
        else
            echo "Оставляем сертификат от $current, $ca_name возьмётся при продлении"
        fi
    fi
fi

# Ежедневная проверка в cron, минута — по IP, чтобы ноды не шли одновременно
install_cron() {
    command -v crontab >/dev/null || { echo 'cron не установлен — автопроверки не будет'; return; }
    local line="$(( ${ip##*.} % 60 )) 4 * * * bash /root/selfsteal.sh --check >> /var/log/selfsteal.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v 'selfsteal.sh' || true; echo "$line" ) | crontab -
}

# Ставим сразу, до ожидания: если выпуск не удастся или запуск прервут, cron повторит ночью
install_cron

# Самопроверка глазами проверяющего: всё, что выдало бы подмену. Печатает найденное, при находках — код 1
verify() {
    local problems=() hdr main srv other path tcp udp

    # Наше имя: код ответа и заголовок Server ровно под шаблон, без Alt-Svc
    hdr=$(curl -sk -m 10 -D - -o /dev/null --resolve "$own_host:8443:127.0.0.1" "https://$own_host:8443/")
    main=$(echo "$hdr" | awk 'NR==1{print $2}')
    srv=$(echo "$hdr" | grep -i '^server:' | cut -d' ' -f2- | tr -d '\r' || true)
    [ "$srv" = "$server" ] || problems+=("заголовок Server «${srv:-нет}», ждали «${server:-нет}»")
    grep -qi '^alt-svc' <<< "$hdr" && problems+=('в ответе есть Alt-Svc (HTTP/3)')

    # Чужое имя и случайный путь отвечают так же, как главная
    other=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' --resolve "$foreign_host:8443:127.0.0.1" "https://$foreign_host:8443/")
    [ "$other" = "$main" ] || problems+=("чужое имя отвечает $other, а наше $main")
    path=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' --resolve "$own_host:8443:127.0.0.1" "https://$own_host:8443/robots.txt")
    [ "$path" = "$main" ] || problems+=("случайный путь отвечает $path, а главная $main")

    # Рукопожатие с чужим именем и вовсе без имени: нужно REALITY и сканерам по голому IP
    echo | timeout 10 openssl s_client -connect 127.0.0.1:8443 -servername "$foreign_host" 2>/dev/null \
        | grep -c 'BEGIN CERTIFICATE' >/dev/null || problems+=('на чужое имя нет сертификата (fallback_sni)')
    echo | timeout 10 openssl s_client -connect 127.0.0.1:8443 -noservername 2>/dev/null \
        | grep -c 'BEGIN CERTIFICATE' >/dev/null || problems+=('без имени нет сертификата (default_sni)')

    # Снаружи 8443 закрыт: только 127.0.0.1 и только TCP
    tcp=$(ss -ltn | awk '{print $4}' | grep ':8443$' || true)
    udp=$(ss -lun | awk '{print $4}' | grep ':8443$' || true)
    [ -n "$tcp" ] && grep -qv '^127\.0\.0\.1:8443$' <<< "$tcp" && problems+=('8443 слушает не только 127.0.0.1')
    [ -n "$udp" ] && problems+=('8443 слушает UDP (HTTP/3)')

    # Итог: пусто — всё чисто
    [ ${#problems[@]} -eq 0 ] && return 0
    printf '  - %s\n' "${problems[@]}"
    return 1
}

# Ждём до 4 минут; завис — чистим TXT и перечитываем конфиг Caddy, всего три попытки
for attempt in 1 2 3; do
    for i in $(seq 1 48); do
        sleep 5
        if cert_ok; then

            # Смена домена: новый сертификат есть — убираем старый домен и только теперь меняем ZONE
            if [ -n "$switching" ]; then
                write_caddyfile "$zone_name"
                install_caddyfile
                caddy_reload || docker compose restart >/dev/null
                sleep 3
                set_env ZONE "$zone_name"
                echo "Домен переключён: $switching → $zone_name"
            fi

            # Сертификат есть — проверяем, что прикрытие не выдаёт себя
            if found=$(verify); then
                echo "OK $ip | $template | сертификат от $(cert_issuer) до $(cert_end) | самопроверка пройдена"
                exit 0
            fi
            echo "ОШИБКА $ip: сертификат есть, но самопроверка нашла:"
            echo "$found"
            exit 1
        fi
    done
    [ "$attempt" -lt 3 ] || break
    echo "Попытка $attempt: сертификата нет 4 минуты, перечитываем конфиг Caddy"
    clean_challenges
    caddy_reload || docker compose restart >/dev/null
done

echo "ОШИБКА $ip: сертификат не получен за 3 попытки. Последние строки Caddy:"
docker compose logs caddy --since 15m 2>&1 | grep -Ei 'error|challenge' | tail -5 | cut -c1-300
[ -n "$switching" ] && echo "Нода продолжает работать на старом домене $switching, ZONE не менялся — запустите позже ещё раз"
exit 1
