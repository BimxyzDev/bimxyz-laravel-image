#!/bin/bash
# Bimxyz Official - PHP web launcher (Nginx + PHP-FPM), untuk PHP biasa maupun Laravel.
#
# Aturan utama: SERVER TIDAK PERNAH BERHENTI sendiri. Tidak ada "exit" kecuali saat server di-stop.
# Semua error hanya dicetak ke console, lalu server tetap lanjut (dan console tetap bisa dipakai).
# Root filesystem container read-only: semua yang ditulis ada di /home/container.

H=/home/container
cd "$H" 2>/dev/null || true
exec 4<&0
stty -echo 2>/dev/null

log()  { echo "[Bimxyz] $*"; }
warn() { echo "[Bimxyz][WARNING] $*"; }
err()  { echo "[Bimxyz][ERROR] $*"; }

show_logs() {
    local f
    for f in php-fpm.log php-fpm.out nginx-error.log nginx.out builtin.out; do
        if [ -s "$H/logs/$f" ]; then
            echo "--- logs/$f (tail) ---"
            tail -n 10 "$H/logs/$f"
        fi
    done
    return 0
}

FPM_PID=""; WEB_PID=""; QUEUE_PID=""; SCHED_PID=""; CF_PID=""; SH_PID=""; FWD_PID=""; RESET_REQ=0

cleanup() {
    local p
    for p in "$FWD_PID" "$QUEUE_PID" "$SCHED_PID" "$CF_PID" "$WEB_PID" "$FPM_PID" "$SH_PID"; do
        if [ -n "$p" ]; then
            pkill -TERM -P "$p" 2>/dev/null
            kill -TERM "$p" 2>/dev/null
        fi
    done
    return 0
}
trap 'exit 0' INT TERM
trap 'RESET_REQ=1' USR1
trap cleanup EXIT

# ---------------------------------------------------------------- binaries
PHP_BIN="$(command -v php 2>/dev/null)"
FPM_BIN="$(command -v php-fpm 2>/dev/null)"
NGINX_BIN="$(command -v nginx 2>/dev/null)"
COMPOSER_BIN="$(command -v composer 2>/dev/null)"
export COMPOSER_MEMORY_LIMIT=-1

WEB_OK=1
[ -n "$PHP_BIN" ]   || { err "php tidak ditemukan di image. Web server tidak dijalankan."; WEB_OK=0; }
[ -n "$FPM_BIN" ]   || warn "php-fpm tidak ditemukan; memakai server bawaan PHP."
[ -n "$NGINX_BIN" ] || warn "nginx tidak ditemukan; memakai server bawaan PHP."

# ---------------------------------------------------------------- validasi env (selalu ada fallback)
PORT="${SERVER_PORT:-}"
case "$PORT" in
    ''|*[!0-9]*) err "SERVER_PORT kosong atau bukan angka. Web server tidak dijalankan."; WEB_OK=0 ;;
esac

FPM_CHILDREN="${PHP_FPM_MAX_CHILDREN:-5}"
case "$FPM_CHILDREN" in
    ''|*[!0-9]*) warn "PHP_FPM_MAX_CHILDREN tidak valid, memakai 5."; FPM_CHILDREN=5 ;;
esac
[ "$FPM_CHILDREN" -ge 1 ]   || FPM_CHILDREN=1
[ "$FPM_CHILDREN" -le 100 ] || FPM_CHILDREN=100
FPM_START=2; FPM_MIN_SPARE=1; FPM_MAX_SPARE=3
[ "$FPM_CHILDREN" -lt 2 ] && FPM_START="$FPM_CHILDREN"
[ "$FPM_CHILDREN" -lt 3 ] && FPM_MAX_SPARE="$FPM_CHILDREN"

POST_MAX="${PHP_POST_MAX_SIZE:-100M}"
if ! echo "$POST_MAX" | grep -Eq '^[0-9]+[KMGkmg]?$'; then
    warn "PHP_POST_MAX_SIZE tidak valid, memakai 100M."
    POST_MAX=100M
fi

[ -n "$PHP_BIN" ] && log "Using $("$PHP_BIN" -v 2>/dev/null | head -n 1)"

# ---------------------------------------------------------------- folder kerja
WEBROOT="$H/webroot"
mkdir -p "$WEBROOT" "$H/logs" "$H/nginx" "$H/php-fpm" "$H/php/conf.d" \
         "$H/tmp/sessions" "$H/tmp/nginx/body" "$H/tmp/nginx/proxy" \
         "$H/tmp/nginx/fastcgi" "$H/tmp/nginx/uwsgi" "$H/tmp/nginx/scgi" 2>/dev/null
rm -f "$H/tmp/php-fpm.sock" "$H/tmp/php-fpm.pid" "$H/tmp/nginx.pid"

# ---------------------------------------------------------------- PHP ini
if [ -n "$PHP_BIN" ]; then
    DEFSCAN="$("$PHP_BIN" --ini 2>/dev/null | sed -n 's/^Scan for additional .ini files in: //p' | sed 's/[[:space:]]*$//')"
    case "$DEFSCAN" in
        ''|'(none)') DEFSCAN="/usr/local/etc/php/conf.d" ;;
    esac
    export PHP_INI_SCAN_DIR="$DEFSCAN:$H/php/conf.d"
fi

cat > "$H/php/conf.d/99-bimxyz.ini" <<EOF_PHP
expose_php=Off
display_errors=Off
log_errors=On
memory_limit=${PHP_MEMORY_LIMIT:-256M}
max_execution_time=${PHP_MAX_EXECUTION_TIME:-120}
max_input_time=${PHP_MAX_INPUT_TIME:-120}
upload_max_filesize=${PHP_UPLOAD_MAX_FILESIZE:-100M}
post_max_size=${POST_MAX}
sys_temp_dir=$H/tmp
upload_tmp_dir=$H/tmp
session.save_path=$H/tmp/sessions
realpath_cache_size=4096K
realpath_cache_ttl=600
EOF_PHP

if [ -n "$PHP_BIN" ] && [ "${OPCACHE_STATUS:-1}" = "1" ] && "$PHP_BIN" -m 2>/dev/null | grep -qi '^Zend OPcache$'; then
    cat >> "$H/php/conf.d/99-bimxyz.ini" <<EOF_OPCACHE
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=${OPCACHE_MEMORY:-64}
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=${OPCACHE_VALIDATE_TIMESTAMPS:-1}
opcache.revalidate_freq=2
EOF_OPCACHE
fi

# ---------------------------------------------------------------- PHP-FPM conf
cat > "$H/php-fpm/php-fpm.conf" <<EOF_FPM
[global]
pid = $H/tmp/php-fpm.pid
error_log = $H/logs/php-fpm.log
daemonize = no

[www]
listen = $H/tmp/php-fpm.sock
pm = dynamic
pm.max_children = $FPM_CHILDREN
pm.start_servers = $FPM_START
pm.min_spare_servers = $FPM_MIN_SPARE
pm.max_spare_servers = $FPM_MAX_SPARE
pm.max_requests = 500
request_terminate_timeout = 120s
clear_env = no
catch_workers_output = yes
decorate_workers_output = no
php_admin_value[error_log] = $H/logs/php-error.log
php_admin_flag[log_errors] = on
EOF_FPM

# ---------------------------------------------------------------- Git (opsional, tidak fatal)
if [ -n "${GIT_ADDRESS:-}" ]; then
    GIT_URL="${GIT_ADDRESS}"
    case "$GIT_URL" in *.git) ;; *) GIT_URL="${GIT_URL}.git" ;; esac
    ASKPASS="$H/.git-askpass"
    if [ -n "${GIT_USERNAME:-}" ] || [ -n "${GIT_ACCESS_TOKEN:-}" ]; then
        cat > "$ASKPASS" <<'EOF_ASKPASS'
#!/bin/ash
case "$1" in
    *Username*) printf '%s\n' "${GIT_USERNAME:-}" ;;
    *) printf '%s\n' "${GIT_ACCESS_TOKEN:-}" ;;
esac
EOF_ASKPASS
        chmod 0700 "$ASKPASS"
        export GIT_ASKPASS="$ASKPASS"
        export GIT_TERMINAL_PROMPT=0
    fi

    if [ -d "$WEBROOT/.git" ]; then
        if [ "${GIT_AUTO_PULL:-0}" = "1" ]; then
            log "Git auto-pull enabled (ff-only)."
            git -C "$WEBROOT" pull --ff-only || warn "Git auto-pull gagal (lanjut dengan file yang ada)."
        fi
    elif [ -z "$(ls -A "$WEBROOT" 2>/dev/null)" ]; then
        log "Cloning repository..."
        if [ -n "${GIT_BRANCH:-}" ]; then
            git clone --depth 1 --single-branch --branch "$GIT_BRANCH" "$GIT_URL" "$WEBROOT" || warn "Git clone gagal."
        else
            git clone --depth 1 "$GIT_URL" "$WEBROOT" || warn "Git clone gagal."
        fi
    else
        warn "webroot sudah berisi file dan bukan repo Git; clone dilewati."
    fi
    rm -f "$ASKPASS"
fi

# ---------------------------------------------------------------- halaman bawaan kalau webroot kosong
if [ -z "$(ls -A "$WEBROOT" 2>/dev/null)" ]; then
    cat > "$WEBROOT/index.php" <<'EOF_INDEX'
<?php
header('Content-Type: text/html; charset=utf-8');
?><!doctype html>
<html lang="id"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Server PHP aktif</title>
<style>body{font-family:system-ui,sans-serif;background:#0d1117;color:#e6edf3;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}
.c{max-width:520px;padding:24px}h1{font-size:22px}code{background:#21262d;padding:2px 6px;border-radius:4px}</style></head>
<body><div class="c"><h1>Server PHP aktif</h1>
<p>PHP <?php echo htmlspecialchars(PHP_VERSION, ENT_QUOTES, 'UTF-8'); ?> berjalan normal.</p>
<p>Upload file website kamu ke folder <code>webroot</code> lewat File Manager, lalu refresh halaman ini.</p></div></body></html>
EOF_INDEX
    log "webroot kosong: membuat halaman bawaan index.php."
fi

# ---------------------------------------------------------------- tentukan document root
DOCROOT="$WEBROOT"
IS_LARAVEL=0
[ -f "$WEBROOT/artisan" ] && IS_LARAVEL=1

CUSTOM_ROOT="${DOCUMENT_ROOT_DIR:-}"
CUSTOM_ROOT="${CUSTOM_ROOT#/}"
CUSTOM_ROOT="${CUSTOM_ROOT%/}"
if [ -n "$CUSTOM_ROOT" ]; then
    if echo "$CUSTOM_ROOT" | grep -Eq '^[A-Za-z0-9_./-]+$' && [ "${CUSTOM_ROOT#*..}" = "$CUSTOM_ROOT" ] && [ -d "$WEBROOT/$CUSTOM_ROOT" ]; then
        DOCROOT="$WEBROOT/$CUSTOM_ROOT"
    else
        warn "DOCUMENT_ROOT_DIR '$CUSTOM_ROOT' tidak valid atau tidak ada; memakai pilihan otomatis."
        CUSTOM_ROOT=""
    fi
fi
if [ -z "$CUSTOM_ROOT" ] && [ "$IS_LARAVEL" = "1" ] && [ -d "$WEBROOT/public" ]; then
    DOCROOT="$WEBROOT/public"
fi
if [ "$IS_LARAVEL" = "1" ]; then
    log "Mode: Laravel (document root: ${DOCROOT#$H/})"
else
    log "Mode: PHP umum (document root: ${DOCROOT#$H/})"
fi

# ---------------------------------------------------------------- Composer (PHP umum & Laravel, tidak fatal)
run_composer() {
    [ -n "$PHP_BIN" ] && [ -n "$COMPOSER_BIN" ] || return 0
    [ "${COMPOSER_AUTO_INSTALL:-1}" = "1" ] && [ -f "$WEBROOT/composer.json" ] || return 0
    cd "$WEBROOT" || return 0
    local mode="${COMPOSER_MODE:-install}" nodev=""
    [ "${COMPOSER_NO_DEV:-1}" = "1" ] && nodev="--no-dev"
    case "$mode" in
        none) ;;
        update)
            log "Running Composer update (explicitly requested)."
            "$PHP_BIN" "$COMPOSER_BIN" update --no-interaction --prefer-dist $nodev --optimize-autoloader || warn "Composer update gagal."
            ;;
        *)
            [ "$mode" = "install" ] || warn "COMPOSER_MODE '$mode' tidak dikenal, memakai install."
            if [ "${COMPOSER_FORCE_INSTALL:-0}" = "1" ] || [ ! -f vendor/autoload.php ]; then
                log "Running Composer install."
                "$PHP_BIN" "$COMPOSER_BIN" install --no-interaction --prefer-dist $nodev --optimize-autoloader || warn "Composer install gagal."
            fi
            ;;
    esac
    if [ -n "${COMPOSER_EXTRA_PACKAGES:-}" ] && [ "${COMPOSER_EXTRA_ON_START:-0}" = "1" ]; then
        log "Installing extra Composer packages."
        # tanpa tanda kutip: beberapa paket (dipisah spasi) terbaca satu per satu
        "$PHP_BIN" "$COMPOSER_BIN" require ${COMPOSER_EXTRA_PACKAGES} --no-interaction || warn "Composer require gagal."
    fi
    return 0
}

# ---------------------------------------------------------------- Laravel bootstrap (hanya kalau ada artisan, tidak fatal)
run_laravel() {
    [ "$IS_LARAVEL" = "1" ] && [ -n "$PHP_BIN" ] || return 0
    cd "$WEBROOT" || return 0

    if [ "${CREATE_ENV_FILE:-1}" = "1" ] && [ ! -f .env ] && [ -f .env.example ]; then
        log "Creating .env from .env.example."
        cp .env.example .env
    fi

    if [ ! -f vendor/autoload.php ]; then
        warn "vendor/autoload.php tidak ada; langkah artisan dilewati. Upload folder vendor/ atau aktifkan Composer."
        return 0
    fi

    if [ "${GENERATE_APP_KEY:-1}" = "1" ] && [ -f .env ]; then
        local key
        key="$(grep -E '^APP_KEY=' .env | head -n 1 | cut -d= -f2-)"
        if [ -z "$key" ]; then
            log "Generating Laravel APP_KEY."
            "$PHP_BIN" artisan key:generate --force || warn "APP_KEY generation gagal."
        fi
    fi

    mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views storage/logs bootstrap/cache
    chmod -R ug+rwX storage bootstrap/cache 2>/dev/null

    [ "${RUN_STORAGE_LINK:-1}" = "1" ] && { "$PHP_BIN" artisan storage:link --force || warn "storage:link gagal."; }
    if [ "${RUN_MIGRATIONS:-0}" = "1" ]; then
        log "Running database migrations."
        "$PHP_BIN" artisan migrate --force || warn "Migrasi database gagal."
    fi
    [ "${RUN_OPTIMIZE:-1}" = "1" ] && { "$PHP_BIN" artisan optimize || warn "Laravel optimize gagal."; }
    [ "${CLEAR_CACHES:-0}" = "1" ] && { "$PHP_BIN" artisan optimize:clear || warn "Laravel cache clear gagal."; }
    return 0
}

run_composer
run_laravel
cd "$H" 2>/dev/null || true

# ---------------------------------------------------------------- Nginx conf
MIME_LINE=""
[ -f /etc/nginx/mime.types ] && MIME_LINE="include /etc/nginx/mime.types;"
ACCESS_LINE="access_log off;"
[ "${NGINX_ACCESS_LOG:-0}" = "1" ] && ACCESS_LINE="access_log $H/logs/access.log;"

sed -e "s#__HOME__#$H#g" \
    -e "s#__ROOT__#$DOCROOT#g" \
    -e "s#__PORT__#${PORT:-8080}#g" \
    -e "s#__MAXBODY__#$POST_MAX#g" \
    -e "s#__MIME__#$MIME_LINE#g" \
    -e "s#__ACCESSLOG__#$ACCESS_LINE#g" > "$H/nginx/nginx.conf" <<'EOF_NGINX'
worker_processes 2;
daemon off;
pid __HOME__/tmp/nginx.pid;
error_log __HOME__/logs/nginx-error.log warn;

events {
    worker_connections 1024;
}

http {
    __MIME__
    default_type application/octet-stream;
    charset utf-8;
    server_tokens off;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 30;
    client_max_body_size __MAXBODY__;
    client_body_timeout 120s;

    client_body_temp_path __HOME__/tmp/nginx/body;
    proxy_temp_path       __HOME__/tmp/nginx/proxy;
    fastcgi_temp_path     __HOME__/tmp/nginx/fastcgi;
    uwsgi_temp_path       __HOME__/tmp/nginx/uwsgi;
    scgi_temp_path        __HOME__/tmp/nginx/scgi;

    __ACCESSLOG__

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;

    # Di belakang Cloudflare / proxy: HTTPS dikenali dari X-Forwarded-Proto
    map $http_x_forwarded_proto $fcgi_https {
        default $https;
        https   on;
    }

    server {
        listen __PORT__;
        server_name _;

        root __ROOT__;
        index index.php index.html index.htm;

        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;

        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }

        location = /favicon.ico { access_log off; log_not_found off; }
        location = /robots.txt  { access_log off; log_not_found off; }

        # File tersembunyi (.env, .git, dll) dan composer.json/lock tidak boleh diakses
        location ~ /\.(?!well-known) {
            deny all;
        }
        location ~* ^/composer\.(json|lock)$ {
            deny all;
        }

        location ~ \.php$ {
            try_files $uri =404;
            fastcgi_pass unix:__HOME__/tmp/php-fpm.sock;
            fastcgi_index index.php;

            fastcgi_param QUERY_STRING       $query_string;
            fastcgi_param REQUEST_METHOD     $request_method;
            fastcgi_param CONTENT_TYPE       $content_type;
            fastcgi_param CONTENT_LENGTH     $content_length;
            fastcgi_param SCRIPT_NAME        $fastcgi_script_name;
            fastcgi_param REQUEST_URI        $request_uri;
            fastcgi_param DOCUMENT_URI       $document_uri;
            fastcgi_param DOCUMENT_ROOT      $document_root;
            fastcgi_param SERVER_PROTOCOL    $server_protocol;
            fastcgi_param REQUEST_SCHEME     $scheme;
            fastcgi_param HTTPS              $fcgi_https if_not_empty;
            fastcgi_param GATEWAY_INTERFACE  CGI/1.1;
            fastcgi_param SERVER_SOFTWARE    nginx/$nginx_version;
            fastcgi_param REMOTE_ADDR        $remote_addr;
            fastcgi_param REMOTE_PORT        $remote_port;
            fastcgi_param SERVER_ADDR        $server_addr;
            fastcgi_param SERVER_PORT        $server_port;
            fastcgi_param SERVER_NAME        $server_name;
            fastcgi_param REDIRECT_STATUS    200;
            fastcgi_param SCRIPT_FILENAME    $document_root$fastcgi_script_name;
            fastcgi_param HTTP_PROXY         "";

            fastcgi_buffer_size 16k;
            fastcgi_buffers 16 16k;
            fastcgi_connect_timeout 60s;
            fastcgi_send_timeout 120s;
            fastcgi_read_timeout 120s;
        }
    }
}
EOF_NGINX

# Router cadangan untuk server bawaan PHP (dipakai kalau Nginx tidak bisa jalan)
cat > "$H/php/router.php" <<'EOF_ROUTER'
<?php
// Cadangan "php -S" kalau Nginx gagal. Meniru: try_files $uri $uri/ /index.php
$root = $_SERVER['DOCUMENT_ROOT'];
$uri = rawurldecode((string) parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH));
if (preg_match('#(^|/)\.(?!well-known)#', $uri) || preg_match('#^/composer\.(json|lock)$#', $uri)) {
    http_response_code(403);
    exit('Forbidden');
}
$file = $root . $uri;
if ($uri !== '/' && is_file($file)) {
    return false;
}
if (is_dir($file) && is_file(rtrim($file, '/') . '/index.php')) {
    $dir = rtrim($file, '/');
    $_SERVER['SCRIPT_NAME'] = rtrim($uri, '/') . '/index.php';
    $_SERVER['SCRIPT_FILENAME'] = $dir . '/index.php';
    chdir($dir);
    require $dir . '/index.php';
    return true;
}
$index = $root . '/index.php';
if (is_file($index)) {
    $_SERVER['SCRIPT_NAME'] = '/index.php';
    $_SERVER['SCRIPT_FILENAME'] = $index;
    chdir($root);
    require $index;
    return true;
}
http_response_code(404);
echo 'Not Found';
EOF_ROUTER

# ---------------------------------------------------------------- tes konfigurasi, pilih mode web
WEB_MODE="nginx"
if [ "$WEB_OK" = "1" ]; then
    if [ -z "$FPM_BIN" ] || [ -z "$NGINX_BIN" ]; then
        WEB_MODE="builtin"
    else
        log "Testing PHP-FPM configuration."
        if ! "$FPM_BIN" -t -y "$H/php-fpm/php-fpm.conf" > "$H/logs/php-fpm-config-test.log" 2>&1; then
            cat "$H/logs/php-fpm-config-test.log"
            warn "Tes konfigurasi PHP-FPM gagal; memakai server bawaan PHP."
            WEB_MODE="builtin"
        fi
        log "Testing Nginx configuration."
        if ! "$NGINX_BIN" -t -e "$H/logs/nginx-error.log" -c "$H/nginx/nginx.conf" -p "$H/" > "$H/logs/nginx-config-test.log" 2>&1; then
            cat "$H/logs/nginx-config-test.log"
            warn "Tes konfigurasi Nginx gagal; memakai server bawaan PHP."
            WEB_MODE="builtin"
        fi
    fi
fi

# ---------------------------------------------------------------- fungsi start proses web
FPM_LAST=0; WEB_LAST=0; WEB_FAILS=0; FPM_FAILS=0

start_fpm() {
    "$FPM_BIN" -F -y "$H/php-fpm/php-fpm.conf" > "$H/logs/php-fpm.out" 2>&1 &
    FPM_PID=$!
    FPM_LAST=$(date +%s)
}

start_web() {
    if [ "$WEB_MODE" = "nginx" ]; then
        "$NGINX_BIN" -e "$H/logs/nginx-error.log" -c "$H/nginx/nginx.conf" -p "$H/" > "$H/logs/nginx.out" 2>&1 &
    else
        PHP_CLI_SERVER_WORKERS="$FPM_CHILDREN" "$PHP_BIN" -S "0.0.0.0:${PORT}" -t "$DOCROOT" "$H/php/router.php" > "$H/logs/builtin.out" 2>&1 &
    fi
    WEB_PID=$!
    WEB_LAST=$(date +%s)
}

if [ "$WEB_OK" = "1" ]; then
    if [ "$WEB_MODE" = "nginx" ]; then
        log "Starting PHP-FPM."
        start_fpm
        log "Starting Nginx on port ${PORT}."
    else
        log "Starting PHP built-in web server on port ${PORT}."
    fi
    start_web

    # cek kesiapan di latar belakang (tidak menahan console)
    rm -f "$H/tmp/.ready-check"
    if command -v curl >/dev/null 2>&1; then
        (
            i=0
            while [ "$i" -lt 30 ]; do
                CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${PORT}/" 2>/dev/null)"
                case "$CODE" in
                    1*|2*|3*|4*|5*) log "HTTP service is accepting requests on port ${PORT}."; : > "$H/tmp/.ready-check"; exit 0 ;;
                esac
                sleep 1
                i=$((i + 1))
            done
            warn "Web server belum menjawab di port ${PORT} setelah 30 detik."
            : > "$H/tmp/.ready-check"
        ) &
    else
        : > "$H/tmp/.ready-check"
    fi
fi

# ---------------------------------------------------------------- queue worker & scheduler (Laravel saja)
HAS_VENDOR=0
[ -f "$WEBROOT/vendor/autoload.php" ] && HAS_VENDOR=1

if [ "${QUEUE_WORKER_STATUS:-0}" = "1" ]; then
    if [ "$IS_LARAVEL" = "1" ] && [ "$HAS_VENDOR" = "1" ] && [ -n "$PHP_BIN" ]; then
        log "Starting Laravel queue worker."
        (
            cd "$WEBROOT" || exit 0
            while true; do
                "$PHP_BIN" artisan queue:work --sleep="${QUEUE_SLEEP:-3}" --tries="${QUEUE_TRIES:-3}" --timeout="${QUEUE_TIMEOUT:-90}" --no-interaction >>"$H/logs/queue.log" 2>&1
                sleep 2
            done
        ) &
        QUEUE_PID=$!
    else
        warn "Queue worker dilewati: ini bukan project Laravel atau vendor/ belum ada."
    fi
fi

if [ "${SCHEDULER_STATUS:-0}" = "1" ]; then
    if [ "$IS_LARAVEL" = "1" ] && [ "$HAS_VENDOR" = "1" ] && [ -n "$PHP_BIN" ]; then
        log "Starting Laravel scheduler."
        (
            cd "$WEBROOT" || exit 0
            while true; do
                "$PHP_BIN" artisan schedule:run --no-interaction >>"$H/logs/scheduler.log" 2>&1
                sleep 60
            done
        ) &
        SCHED_PID=$!
    else
        warn "Scheduler dilewati: ini bukan project Laravel atau vendor/ belum ada."
    fi
fi

# ---------------------------------------------------------------- Cloudflare Tunnel
# CF_TUNNEL_STATUS=1: token kosong -> Quick Tunnel (domain trycloudflare otomatis), token diisi -> tunnel token.
# Log: /home/container/cloudflare.log
start_cloudflare() {
    [ "${CF_TUNNEL_STATUS:-0}" = "1" ] || return 0
    [ "$WEB_OK" = "1" ] || { warn "Cloudflare Tunnel dilewati: web server tidak berjalan."; return 0; }

    # Semua (unduh + jalan) di latar belakang supaya start server & console tidak pernah tertahan.
    (
        CFLOG="$H/cloudflare.log"
        CFBIN="$H/cloudflared"
        token="${CF_TUNNEL_TOKEN:-}"
        token="${token//[[:space:]]/}"

        touch "$CFLOG" 2>/dev/null
        if [ -f "$CFLOG" ] && [ "$(wc -c < "$CFLOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
            : > "$CFLOG"
        fi

        if [ ! -x "$CFBIN" ]; then
            log "cloudflared belum ada, mengunduh dari rilis resmi Cloudflare..."
            case "$(uname -m)" in
                x86_64|amd64) arch="amd64" ;;
                aarch64|arm64) arch="arm64" ;;
                *) arch="" ;;
            esac
            if [ -n "$arch" ] && curl -fsSL --retry 3 --connect-timeout 20 --max-time 180 \
                    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" \
                    -o "$CFBIN" >>"$CFLOG" 2>&1; then
                chmod 0755 "$CFBIN"
                "$CFBIN" version >>"$CFLOG" 2>&1 || rm -f "$CFBIN"
            else
                rm -f "$CFBIN"
            fi
        fi
        if [ ! -x "$CFBIN" ]; then
            err "cloudflared tidak tersedia (unduh gagal). Detail di cloudflare.log. Server tetap berjalan tanpa tunnel."
            exit 0
        fi

        if [ -n "$token" ]; then
            log "Starting Cloudflare Tunnel (token). Log: cloudflare.log"
        else
            log "CF_TUNNEL_TOKEN kosong: memakai Quick Tunnel (domain trycloudflare.com otomatis). Log: cloudflare.log"
        fi

        while true; do
            off="$(wc -c < "$CFLOG" 2>/dev/null || echo 0)"
            if [ -n "$token" ]; then
                "$CFBIN" tunnel --no-autoupdate run --token "$token" >>"$CFLOG" 2>&1 &
            else
                "$CFBIN" tunnel --no-autoupdate --url "http://127.0.0.1:${PORT}" >>"$CFLOG" 2>&1 &
            fi
            cfpid=$!
            if [ -z "$token" ]; then
                n=0
                while [ "$n" -lt 40 ]; do
                    sleep 1
                    url="$(tail -c +$((off + 1)) "$CFLOG" 2>/dev/null | grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' | tail -n 1)"
                    if [ -n "$url" ]; then
                        echo "[Bimxyz] Cloudflare Quick Tunnel: $url"
                        break
                    fi
                    kill -0 "$cfpid" 2>/dev/null || break
                    n=$((n + 1))
                done
            fi
            wait "$cfpid"
            echo "[Bimxyz][WARNING] cloudflared berhenti; mencoba lagi dalam 5 detik (lihat cloudflare.log)."
            sleep 5
        done
    ) &
    CF_PID=$!
    return 0
}
start_cloudflare

# ---------------------------------------------------------------- console interaktif (shell bash permanen)
CONSOLE_FIFO="$H/tmp/console.fifo"
rm -f "$CONSOLE_FIFO"
CONSOLE_OK=0
if mkfifo "$CONSOLE_FIFO" 2>/dev/null && exec 3<>"$CONSOLE_FIFO"; then
    CONSOLE_OK=1
else
    warn "Console interaktif tidak bisa dibuat (mkfifo gagal)."
fi

# Fungsi yang dimuat ke shell console: helper artisan + prompt berwarna
shell_init() {
    printf 'artisan() { ( cd "%s/webroot" && php artisan "$@" ); }\n' "$H" >&3
    cat >&3 <<'EOF_SHELLINIT'
__bx_prompt() {
    local rc=$? p="$PWD" st=""
    case "$p" in
        "$HOME") p="~" ;;
        "$HOME"/*) p="~/${p#"$HOME"/}" ;;
    esac
    [ "$rc" -ne 0 ] && st=" $(printf '\033[1;31m✘ %s\033[0m' "$rc")"
    printf '\n\033[1;35m╭─\033[0m \033[1;36m%s\033[0m\033[90m@\033[0m\033[1;34mbimxyz\033[0m \033[1;33m%s\033[0m%s\n\033[1;35m╰─❯\033[0m ' "${USER:-container}" "$p" "$st"
}
EOF_SHELLINIT
}

start_shell() {
    # buang sisa input lama di fifo (mis. setelah 'exit') supaya tidak dibaca shell baru
    while IFS= read -r -t 0.2 -u 3 _junk; do :; done
    ( cd "$H" 2>/dev/null; exec bash --norc --noprofile ) <&3 &
    SH_PID=$!
    shell_init
    [ "$1" = "prompt" ] && printf '__bx_prompt\n' >&3
}

reset_shell() {
    warn "Mereset shell console."
    if [ -n "$SH_PID" ]; then
        pkill -TERM -P "$SH_PID" 2>/dev/null
        kill -TERM "$SH_PID" 2>/dev/null
    fi
    sleep 1
    start_shell prompt
}

# Pembaca stdin (console). Menampilkan perintah yang diketik di baris prompt, lalu meneruskannya ke shell.
start_forwarder() {
    local main=$$
    (
        while IFS= read -r LINE; do
            LINE="${LINE%$'\r'}"
            case "$LINE" in
                .reset) printf '\n'; kill -USR1 "$main" 2>/dev/null ;;
                '') printf '\n'; printf '__bx_prompt\n' >&3 ;;
                *) printf '%s\n' "$LINE"; printf '%s\n__bx_prompt\n' "$LINE" >&3 ;;
            esac
        done
    ) <&4 &
    FWD_PID=$!
}

if [ "$CONSOLE_OK" = "1" ]; then
    start_shell
    log "Console aktif: ketik perintah bash apa saja (cd, ls, php, composer, artisan ...). Ketik .reset kalau ada perintah yang menggantung."
fi

# Tunggu web siap (maks 10 detik) supaya pesan latar belakang tidak menyela baris prompt
w=0
while [ "$WEB_OK" = "1" ] && [ ! -e "$H/tmp/.ready-check" ] && [ "$w" -lt 50 ]; do
    sleep 0.2
    w=$((w + 1))
done

if [ "$WEB_OK" = "1" ]; then
    log "Server is running."
else
    log "Server is running (mode console saja; web server tidak aktif, lihat pesan ERROR di atas)."
fi

# prompt pertama, lalu mulai membaca perintah dari console
if [ "$CONSOLE_OK" = "1" ]; then
    printf '__bx_prompt\n' >&3
    start_forwarder
fi

# ---------------------------------------------------------------- loop utama: console + pengawas (tidak pernah keluar)
supervise() {
    local now life
    now=$(date +%s)

    if [ "$WEB_OK" = "1" ]; then
        # PHP-FPM
        if [ "$WEB_MODE" = "nginx" ] && ! kill -0 "$FPM_PID" 2>/dev/null; then
            if [ $((now - FPM_LAST)) -ge 5 ]; then
                warn "PHP-FPM berhenti; menjalankan ulang."
                show_logs
                start_fpm
            fi
        fi
        # web server (Nginx / bawaan PHP)
        if ! kill -0 "$WEB_PID" 2>/dev/null; then
            life=$((now - WEB_LAST))
            local delay=$((WEB_FAILS * 3 + 3))
            [ "$delay" -gt 30 ] && delay=30
            if [ "$life" -ge "$delay" ]; then
                if [ "$life" -lt 60 ]; then WEB_FAILS=$((WEB_FAILS + 1)); else WEB_FAILS=1; fi
                warn "Web server ($WEB_MODE) berhenti; menjalankan ulang (gagal berturut-turut: $WEB_FAILS)."
                show_logs
                if [ "$WEB_MODE" = "nginx" ] && [ "$WEB_FAILS" -ge 3 ] && [ -n "$PHP_BIN" ]; then
                    warn "Nginx terus gagal; pindah ke server bawaan PHP supaya website tetap hidup."
                    WEB_MODE="builtin"
                    WEB_FAILS=0
                fi
                start_web
            fi
        fi
    fi

    if [ "$CONSOLE_OK" = "1" ] && ! kill -0 "$SH_PID" 2>/dev/null; then
        start_shell prompt
    fi
    return 0
}

while true; do
    if [ "$RESET_REQ" = "1" ]; then
        RESET_REQ=0
        [ "$CONSOLE_OK" = "1" ] && reset_shell
    fi
    supervise
    sleep 1 &
    wait $!
done
