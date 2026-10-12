#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# СЕЛФСТИЛ: сайт-прикрытие для REALITY на 127.0.0.1:8443
#
# Один скрипт на все ноды, можно запускать на всех одновременно: ноды выстраиваются
# в очередь через замок в DNS Cloudflare и выпускают сертификат по одной.
#
# Ключи: переменные окружения CF_API_TOKEN, ZEROSSL_KID, ZEROSSL_HMAC → /root/caddy/.env → вопрос.
# Сайт: /root/caddy/site/index.html — одна из стандартных страниц веб-серверов, выбор по IP ноды,
#       постоянный. Нет файла — вопрос: шаблон по умолчанию или свой HTML до строки END.
#       Сменить страницу: rm /root/caddy/site/index.html и запустить снова.
# Сертификат: wildcard *.vpnon-connect.tech от ZeroSSL, проверка домена через DNS Cloudflare.
#             Завис выпуск — скрипт сам перезапускает Caddy, до трёх попыток.
#
# Запуск:  bash /root/selfsteal.sh           установить или починить (сертификат из тома сохраняется)
#          bash /root/selfsteal.sh --reset   то же, но сертификат и аккаунт ZeroSSL с нуля
#          bash /root/selfsteal.sh --check   проверка для cron: всё живо и сертификату больше 21 дня —
#                                            ничего не делает, иначе чинит как обычный запуск
# При каждом запуске скрипт сам ставит ежедневную проверку в cron (лог /var/log/selfsteal.log).
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

zone_name=vpnon-connect.tech
lock_name="_selfsteal-lock.$zone_name"
lock_ttl=1200
mode=${1:-}
ip=$(hostname -I | awk '{print $1}')

# Cron вызывает /root/selfsteal.sh — кладём туда копию, если запустили из другого места
self=$(readlink -f "$0" 2>/dev/null || true)
[ -f "$self" ] && [ "$self" != /root/selfsteal.sh ] && cp "$self" /root/selfsteal.sh
mkdir -p /root/caddy/site && cd /root/caddy

# Нода в порядке: страница отвечает на 8443, на чужое имя тоже есть ответ TLS (см. fallback_sni)
# и сертификат действует ещё больше 21 дня
cert_ok() {
    curl -sk -m 10 -o /dev/null --resolve "ru.$zone_name:8443:127.0.0.1" "https://ru.$zone_name:8443" || return 1
    echo | timeout 10 openssl s_client -connect 127.0.0.1:8443 -servername fortwine.ru 2>/dev/null \
        | grep -c 'BEGIN CERTIFICATE' >/dev/null || return 1
    echo | timeout 10 openssl s_client -connect 127.0.0.1:8443 -servername "ru.$zone_name" 2>/dev/null \
        | openssl x509 -noout -checkend $((21 * 86400)) >/dev/null 2>&1
}
cert_end() {
    echo | timeout 10 openssl s_client -connect 127.0.0.1:8443 -servername "ru.$zone_name" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2
}

# Проверка из cron: всё в порядке — выходим, ничего не трогая
if [ "$mode" = --check ]; then
    if cert_ok; then
        echo "$(date '+%F %T') OK $ip, сертификат до $(cert_end)"
        exit 0
    fi
    echo "$(date '+%F %T') $ip: страница не отвечает или сертификат скоро истечёт — чиним"
fi

# ─── Ключи ───────────────────────────────────────────────────────────────────
touch .env && chmod 600 .env
key() {
    local value="${!1:-}"
    [ -n "$value" ] || value=$(grep -s "^$1=" .env | cut -d= -f2- || true)
    [ -n "$value" ] || { read -rsp "$2: " value; echo; }
    [ -n "$value" ] || { echo "Нет значения $1"; exit 1; }
    grep -q "^$1=" .env && sed -i "s|^$1=.*|$1=$value|" .env || echo "$1=$value" >> .env
}
key CF_API_TOKEN 'Токен Cloudflare'
key ZEROSSL_KID 'ZeroSSL EAB kid'
key ZEROSSL_HMAC 'ZeroSSL EAB hmac'
set -a; . ./.env; set +a

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
      ZEROSSL_KID: ${ZEROSSL_KID}
      ZEROSSL_HMAC: ${ZEROSSL_HMAC}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./site:/srv:ro
      - data:/data
volumes:
  data:
YAML

# Заголовок Server — под выбранную страницу, у 403 ещё и код ответа.
# Свою проверку TXT Caddy не делает (propagation_timeout -1): на нодах, где DNS режут или он
# тормозит, она зависала навсегда. Cloudflare публикует запись за секунды, 30 секунд ожидания с запасом
server=$(server_header "$template")

# Значение в кавычках: без них «nginx/1.24.0 (Ubuntu)» Caddy читает как «найти и заменить» и заголовок не ставит
header_line=''
[ -n "$server" ] && header_line="header Server \"$server\""
# Блок только многострочный: { status 403 } в одну строку Caddy не принимает и падает на старте
files='file_server'
[ "$template" = nginx-403 ] && files=$'file_server {\n        status 403\n    }'
# fallback_sni: на чужое имя (fortwine.ru, пока он в serverNames) Caddy отвечает нашим сертификатом.
# Без этого он рвёт рукопожатие, а REALITY пускает клиента, только если dest прислал ServerHello —
# клиенты со старым sni после переключения dest перестали бы подключаться
cat > Caddyfile <<CADDY
{
    auto_https disable_redirects
    https_port 8443
    fallback_sni ru.$zone_name
}

*.$zone_name {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
        propagation_delay 30s
        propagation_timeout -1
        ca https://acme.zerossl.com/v2/DV90
        eab {env.ZEROSSL_KID} {env.ZEROSSL_HMAC}
    }
    header -Server
    $header_line
    root * /srv
    $files
}
CADDY

# Проверяем Caddyfile до замка: с ошибкой в конфиге Caddy падает по кругу и сертификат не выпускает
if ! out=$(docker run --rm -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" ghcr.io/caddybuilds/caddy-cloudflare:latest \
        caddy adapt --config /etc/caddy/Caddyfile 2>&1 >/dev/null); then
    echo "ОШИБКА $ip: Caddy не принял Caddyfile:"
    echo "$out" | tail -3
    exit 1
fi

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

# Замок: сертификат в один момент времени выпускает одна нода. Замок старше 20 минут считаем брошенным
echo "Нода $ip: становимся в очередь на выпуск сертификата"
while :; do
    taken=''
    while read -r id content; do
        [ -n "$id" ] || continue
        owner=${content%%:*}; stamp=${content##*:}
        if [ $(( $(date +%s) - stamp )) -gt $lock_ttl ]; then delete "$id"; else taken="$owner"; fi
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
# Обычный запуск сохраняет том: действующий сертификат подхватится без нового выпуска
if [ "$mode" = --reset ]; then
    docker compose down -v >/dev/null 2>&1 || true
fi
docker compose up -d --force-recreate >/dev/null
echo 'Caddy запущен, ждём сертификат от ZeroSSL...'

# Ежедневная проверка в cron, минута — по IP, чтобы ноды не шли одновременно
install_cron() {
    command -v crontab >/dev/null || { echo 'cron не установлен — автопроверки не будет'; return; }
    local line="$(( ${ip##*.} % 60 )) 4 * * * bash /root/selfsteal.sh --check >> /var/log/selfsteal.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v 'selfsteal.sh' || true; echo "$line" ) | crontab -
}

# Ставим сразу, до ожидания: если выпуск не удастся или запуск прервут, cron повторит ночью
install_cron

# Ждём до 4 минут; завис — чистим TXT и перезапускаем Caddy, всего три попытки
for attempt in 1 2 3; do
    for i in $(seq 1 48); do
        sleep 5
        if cert_ok; then
            echo "OK $ip | $template | сертификат до $(cert_end)"
            exit 0
        fi
    done
    [ "$attempt" -lt 3 ] || break
    echo "Попытка $attempt: сертификата нет 4 минуты, перезапускаем Caddy"
    clean_challenges
    docker compose restart >/dev/null
done

echo "ОШИБКА $ip: сертификат не получен за 3 попытки. Последние строки Caddy:"
docker compose logs caddy --since 15m 2>&1 | grep -Ei 'error|challenge' | tail -5 | cut -c1-300
exit 1
