#!/bin/ash
# Bimxyz Official - Laravel launcher (Nginx + PHP-FPM).
# Semua konfigurasi dibuat di sini setiap start. Tidak ada unduhan dari pihak ketiga.
# Root filesystem container read-only: semua yang ditulis ada di /home/container.
set -eu

H=/home/container
cd "$H"

log()  { echo "[Bimxyz] $1"; }
warn() { echo "[Bimxyz][WARNING] $1"; }
fail() { echo "[Bimxyz][ERROR] $1"; exit 1; }

show_logs() {
    for f in php-fpm.log php-fpm.out nginx-error.log nginx.out; do
        if [ -s "$H/logs/$f" ]; then
            echo "--- logs/$f (tail) ---"
            tail -n 15 "$H/logs/$f"
        fi
    done
}

# ---------------------------------------------------------------- binaries
PHP_BIN="$(command -v php 2>/dev/null || true)"
[ -n "$PHP_BIN" ] || fail "php not found in the image."
FPM_BIN="$(command -v php-fpm 2>/dev/null || true)"
[ -n "$FPM_BIN" ] || fail "php-fpm not found in the image."
NGINX_BIN="$(command -v nginx 2>/dev/null || true)"
[ -n "$NGINX_BIN" ] || fail "nginx not found in the image."
COMPOSER_BIN="$(command -v composer 2>/dev/null || true)"
[ -n "$COMPOSER_BIN" ] || fail "composer not found in the image."
export COMPOSER_MEMORY_LIMIT=-1

# ---------------------------------------------------------------- validasi env
PORT="${SERVER_PORT:-}"
case "$PORT" in
    ''|*[!0-9]*) fail "SERVER_PORT is missing or not numeric." ;;
esac

FPM_CHILDREN="${PHP_FPM_MAX_CHILDREN:-5}"
case "$FPM_CHILDREN" in
    ''|*[!0-9]*) fail "PHP_FPM_MAX_CHILDREN must be an integer." ;;
esac
[ "$FPM_CHILDREN" -ge 1 ] || fail "PHP_FPM_MAX_CHILDREN must be >= 1."
[ "$FPM_CHILDREN" -le 100 ] || fail "PHP_FPM_MAX_CHILDREN must be <= 100."
FPM_START=2
FPM_MIN_SPARE=1
FPM_MAX_SPARE=3
[ "$FPM_CHILDREN" -lt 2 ] && FPM_START="$FPM_CHILDREN"
[ "$FPM_CHILDREN" -lt 3 ] && FPM_MAX_SPARE="$FPM_CHILDREN"

POST_MAX="${PHP_POST_MAX_SIZE:-100M}"
echo "$POST_MAX" | grep -Eq '^[0-9]+[KMGkmg]?$' || fail "PHP_POST_MAX_SIZE must look like 100M."

log "Using $("$PHP_BIN" -v 2>/dev/null | head -n 1)"

# ---------------------------------------------------------------- folder kerja
mkdir -p "$H/webroot" "$H/logs" "$H/nginx" "$H/php-fpm" "$H/php/conf.d" \
         "$H/tmp/sessions" "$H/tmp/nginx/body" "$H/tmp/nginx/proxy" \
         "$H/tmp/nginx/fastcgi" "$H/tmp/nginx/uwsgi" "$H/tmp/nginx/scgi"
rm -f "$H/tmp/php-fpm.sock" "$H/tmp/php-fpm.pid" "$H/tmp/nginx.pid"

# ---------------------------------------------------------------- PHP ini
# Folder ini bawaan image tetap dibaca; ini tambahan ada di /home/container/php/conf.d
DEFSCAN="$("$PHP_BIN" --ini 2>/dev/null | sed -n 's/^Scan for additional .ini files in: //p' | sed 's/[[:space:]]*$//')"
case "$DEFSCAN" in
    ''|'(none)') DEFSCAN="/usr/local/etc/php/conf.d" ;;
esac
export PHP_INI_SCAN_DIR="$DEFSCAN:$H/php/conf.d"

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

if [ "${OPCACHE_STATUS:-1}" = "1" ] && "$PHP_BIN" -m 2>/dev/null | grep -qi '^Zend OPcache$'; then
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

# ---------------------------------------------------------------- Nginx conf
MIME_LINE=""
[ -f /etc/nginx/mime.types ] && MIME_LINE="include /etc/nginx/mime.types;"
ACCESS_LINE="access_log off;"
[ "${NGINX_ACCESS_LOG:-0}" = "1" ] && ACCESS_LINE="access_log $H/logs/access.log;"

sed -e "s#__HOME__#$H#g" \
    -e "s#__PORT__#$PORT#g" \
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

        root __HOME__/webroot/public;
        index index.php index.html;

        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;

        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }

        location = /favicon.ico { access_log off; log_not_found off; }
        location = /robots.txt  { access_log off; log_not_found off; }

        # File tersembunyi (.env, .git, dll) tidak boleh diakses
        location ~ /\.(?!well-known) {
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

# ---------------------------------------------------------------- cek aplikasi Laravel
[ -d "$H/webroot/public" ] || [ -n "${GIT_ADDRESS:-}" ] || fail "Folder webroot/public tidak ada. Upload project Laravel ke /home/container/webroot (atau isi Git Repo Address)."

# ---------------------------------------------------------------- Git (opsional)
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

    if [ -d "$H/webroot/.git" ]; then
        if [ "${GIT_AUTO_PULL:-0}" = "1" ]; then
            log "Git auto-pull enabled (ff-only)."
            git -C "$H/webroot" pull --ff-only || { rm -f "$ASKPASS"; fail "Git auto-pull failed."; }
        fi
    elif [ -z "$(ls -A "$H/webroot" 2>/dev/null)" ]; then
        log "Cloning Laravel application repository..."
        if [ -n "${GIT_BRANCH:-}" ]; then
            git clone --depth 1 --single-branch --branch "$GIT_BRANCH" "$GIT_URL" "$H/webroot" || { rm -f "$ASKPASS"; fail "Git clone failed."; }
        else
            git clone --depth 1 "$GIT_URL" "$H/webroot" || { rm -f "$ASKPASS"; fail "Git clone failed."; }
        fi
    else
        warn "webroot already contains files and is not a Git repository; Git clone skipped."
    fi
    rm -f "$ASKPASS"
fi

[ -d "$H/webroot/public" ] || fail "Folder webroot/public tidak ada. Pastikan ini project Laravel."
[ -f "$H/webroot/artisan" ] || fail "File artisan tidak ada di webroot. Egg ini khusus Laravel."

cd "$H/webroot"

# ---------------------------------------------------------------- Laravel bootstrap
if [ "${CREATE_ENV_FILE:-1}" = "1" ] && [ ! -f .env ] && [ -f .env.example ]; then
    log "Creating .env from .env.example."
    cp .env.example .env
fi

if [ "${COMPOSER_AUTO_INSTALL:-1}" = "1" ] && [ -f composer.json ]; then
    COMPOSER_MODE_VALUE="${COMPOSER_MODE:-install}"
    case "$COMPOSER_MODE_VALUE" in
        none) ;;
        install)
            if [ "${COMPOSER_FORCE_INSTALL:-0}" = "1" ] || [ ! -f vendor/autoload.php ]; then
                log "Running Composer install."
                if [ "${COMPOSER_NO_DEV:-1}" = "1" ]; then
                    "$PHP_BIN" "$COMPOSER_BIN" install --no-interaction --prefer-dist --no-dev --optimize-autoloader || fail "Composer install failed."
                else
                    "$PHP_BIN" "$COMPOSER_BIN" install --no-interaction --prefer-dist --optimize-autoloader || fail "Composer install failed."
                fi
            fi
            ;;
        update)
            log "Running Composer update (explicitly requested)."
            if [ "${COMPOSER_NO_DEV:-1}" = "1" ]; then
                "$PHP_BIN" "$COMPOSER_BIN" update --no-interaction --prefer-dist --no-dev --optimize-autoloader || fail "Composer update failed."
            else
                "$PHP_BIN" "$COMPOSER_BIN" update --no-interaction --prefer-dist --optimize-autoloader || fail "Composer update failed."
            fi
            ;;
        *) fail "COMPOSER_MODE must be install, update, or none." ;;
    esac
fi

if [ -n "${COMPOSER_EXTRA_PACKAGES:-}" ] && [ "${COMPOSER_EXTRA_ON_START:-0}" = "1" ]; then
    log "Installing extra Composer packages."
    # tanpa tanda kutip supaya beberapa paket (dipisah spasi) terbaca satu per satu
    "$PHP_BIN" "$COMPOSER_BIN" require ${COMPOSER_EXTRA_PACKAGES} --no-interaction || fail "Composer require failed."
fi

[ -f vendor/autoload.php ] || fail "vendor/autoload.php tidak ada. Upload folder vendor/ atau aktifkan Composer Auto Install (Composer Mode = install)."

# APP_KEY dibuat SETELAH composer (artisan butuh vendor/)
if [ "${GENERATE_APP_KEY:-1}" = "1" ] && [ -f .env ]; then
    APP_KEY_VALUE="$(grep -E '^APP_KEY=' .env | head -n 1 | cut -d= -f2- || true)"
    if [ -z "$APP_KEY_VALUE" ]; then
        log "Generating Laravel APP_KEY."
        "$PHP_BIN" artisan key:generate --force || fail "APP_KEY generation failed."
    fi
fi

mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views storage/logs bootstrap/cache
chmod -R ug+rwX storage bootstrap/cache 2>/dev/null || true

if [ "${RUN_STORAGE_LINK:-1}" = "1" ]; then
    "$PHP_BIN" artisan storage:link --force || warn "storage:link failed (continuing)."
fi

if [ "${RUN_MIGRATIONS:-0}" = "1" ]; then
    log "Running database migrations."
    "$PHP_BIN" artisan migrate --force || fail "Database migration failed."
fi

if [ "${RUN_OPTIMIZE:-1}" = "1" ]; then
    "$PHP_BIN" artisan optimize || warn "Laravel optimize failed (continuing)."
fi

if [ "${CLEAR_CACHES:-0}" = "1" ]; then
    "$PHP_BIN" artisan optimize:clear || fail "Laravel cache clear failed."
fi

cd "$H"

# ---------------------------------------------------------------- tes konfigurasi
log "Testing PHP-FPM configuration."
"$FPM_BIN" -t -y "$H/php-fpm/php-fpm.conf" > "$H/logs/php-fpm-config-test.log" 2>&1 || {
    cat "$H/logs/php-fpm-config-test.log"
    fail "PHP-FPM configuration test failed."
}

log "Testing Nginx configuration."
"$NGINX_BIN" -t -e "$H/logs/nginx-error.log" -c "$H/nginx/nginx.conf" -p "$H/" > "$H/logs/nginx-config-test.log" 2>&1 || {
    cat "$H/logs/nginx-config-test.log"
    fail "Nginx configuration test failed."
}

# ---------------------------------------------------------------- jalankan service
FPM_PID=""
NGINX_PID=""
QUEUE_PID=""
SCHEDULER_PID=""
CF_PID=""

cleanup() {
    set +e
    for p in "$QUEUE_PID" "$SCHEDULER_PID" "$CF_PID" "$NGINX_PID" "$FPM_PID"; do
        [ -n "$p" ] && kill -TERM "$p" 2>/dev/null
    done
    return 0
}
trap 'exit 0' INT TERM
trap cleanup EXIT

log "Starting PHP-FPM."
"$FPM_BIN" -F -y "$H/php-fpm/php-fpm.conf" > "$H/logs/php-fpm.out" 2>&1 &
FPM_PID=$!

log "Starting Nginx on port ${PORT}."
"$NGINX_BIN" -e "$H/logs/nginx-error.log" -c "$H/nginx/nginx.conf" -p "$H/" > "$H/logs/nginx.out" 2>&1 &
NGINX_PID=$!

# Tunggu sampai Nginx menjawab (dilewati kalau curl tidak ada)
if command -v curl >/dev/null 2>&1; then
    READY=0
    i=0
    while [ "$i" -lt 30 ]; do
        CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
        case "$CODE" in
            1*|2*|3*|4*|5*) READY=1; break ;;
        esac
        kill -0 "$NGINX_PID" 2>/dev/null || break
        kill -0 "$FPM_PID" 2>/dev/null || break
        sleep 1
        i=$((i + 1))
    done
    if [ "$READY" = "1" ]; then
        log "HTTP service is accepting requests on port ${PORT}."
    elif kill -0 "$NGINX_PID" 2>/dev/null && kill -0 "$FPM_PID" 2>/dev/null; then
        warn "Nginx did not answer on port ${PORT} within 30s (continuing)."
    else
        show_logs
        fail "Nginx or PHP-FPM exited during startup."
    fi
fi

# ---------------------------------------------------------------- queue worker (opsional)
if [ "${QUEUE_WORKER_STATUS:-0}" = "1" ]; then
    log "Starting Laravel queue worker."
    (
        cd "$H/webroot"
        while true; do
            "$PHP_BIN" artisan queue:work --sleep="${QUEUE_SLEEP:-3}" --tries="${QUEUE_TRIES:-3}" --timeout="${QUEUE_TIMEOUT:-90}" --no-interaction >>"$H/logs/queue.log" 2>&1 || true
            sleep 2
        done
    ) &
    QUEUE_PID=$!
fi

# ---------------------------------------------------------------- scheduler (opsional)
if [ "${SCHEDULER_STATUS:-0}" = "1" ]; then
    log "Starting Laravel scheduler."
    (
        cd "$H/webroot"
        while true; do
            "$PHP_BIN" artisan schedule:run --no-interaction >>"$H/logs/scheduler.log" 2>&1 || true
            sleep 60
        done
    ) &
    SCHEDULER_PID=$!
fi

# ---------------------------------------------------------------- Cloudflare Tunnel (opsional)
CF_MODE="${CF_TUNNEL_MODE:-off}"
case "$CF_MODE" in
    off) ;;
    quick)
        [ -x "$H/cloudflared" ] || fail "cloudflared is missing. Reinstall the server."
        log "Starting Cloudflare Quick Tunnel."
        (
            while true; do
                "$H/cloudflared" tunnel --no-autoupdate --url "http://127.0.0.1:${PORT}" >>"$H/logs/cloudflared.log" 2>&1 || true
                sleep 5
            done
        ) &
        CF_PID=$!
        sleep 3
        QUICK_URL="$(grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$H/logs/cloudflared.log" 2>/dev/null | tail -n 1 || true)"
        [ -n "$QUICK_URL" ] && log "Cloudflare Quick Tunnel: $QUICK_URL"
        ;;
    token)
        [ -x "$H/cloudflared" ] || fail "cloudflared is missing. Reinstall the server."
        [ -n "${CF_TUNNEL_TOKEN:-}" ] || fail "CF_TUNNEL_TOKEN is required for token mode."
        log "Starting Cloudflare remotely-managed Tunnel."
        (
            while true; do
                "$H/cloudflared" tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}" >>"$H/logs/cloudflared.log" 2>&1 || true
                sleep 5
            done
        ) &
        CF_PID=$!
        ;;
    *) fail "CF_TUNNEL_MODE must be off, quick, or token." ;;
esac

log "Laravel production stack is running."

# ---------------------------------------------------------------- jaga proses
while kill -0 "$FPM_PID" 2>/dev/null && kill -0 "$NGINX_PID" 2>/dev/null; do
    sleep 1
done

show_logs
fail "PHP-FPM or Nginx stopped unexpectedly."
