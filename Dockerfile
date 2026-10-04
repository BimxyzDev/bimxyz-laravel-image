# Bimxyz Official - Laravel (Nginx + PHP-FPM) untuk Pterodactyl
# Basis: image PHP resmi (php:<versi>-fpm-alpine). Nginx dari repo Alpine, Composer dari image resmi composer.
#
# Build:  docker build --build-arg PHP_VERSION=8.4 -t bimxyz-laravel:8.4 .
ARG PHP_VERSION=8.4
FROM php:${PHP_VERSION}-fpm-alpine

# Paket runtime (repo resmi Alpine) + library untuk ekstensi PHP
RUN apk add --no-cache \
        nginx tini git curl unzip tzdata iproute2 \
        libzip icu-libs libpng libjpeg-turbo freetype

# Ekstensi PHP lewat helper resmi docker-php-ext-*
RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS libzip-dev icu-dev libpng-dev libjpeg-turbo-dev freetype-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" bcmath exif gd intl mysqli opcache pcntl pdo_mysql zip; \
    apk del .build-deps; \
    rm -rf /tmp/* /var/cache/apk/*

# Composer dari image resmi Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY entrypoint.sh /entrypoint.sh
COPY bimxyz-start.sh /usr/local/bin/bimxyz-start

# Pastikan LF (bukan CRLF) dan bisa dieksekusi, lalu buat user container (wajib untuk Pterodactyl)
RUN sed -i 's/\r$//' /entrypoint.sh /usr/local/bin/bimxyz-start \
    && chmod 0755 /entrypoint.sh /usr/local/bin/bimxyz-start \
    && adduser -D -h /home/container container

# Cek kelengkapan saat build: kalau ada yang hilang, build langsung gagal di sini (bukan saat server start)
RUN set -eux; \
    php -v; php-fpm -v; nginx -v; composer --version; git --version; \
    php -r 'foreach (["pdo_mysql","mysqli","gd","zip","intl","bcmath","mbstring","openssl","tokenizer","xml","ctype","fileinfo","curl","pcntl","exif","Zend OPcache"] as $e) { if (!extension_loaded($e)) { fwrite(STDERR, "extension hilang: $e\n"); exit(1); } }'; \
    test -x /sbin/tini

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

ENTRYPOINT ["/sbin/tini", "-g", "--"]
CMD ["/bin/ash", "/entrypoint.sh"]
