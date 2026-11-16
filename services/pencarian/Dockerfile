FROM composer:2 AS composer

FROM php:8.3-apache

RUN apt-get update && apt-get install -y --no-install-recommends git unzip libonig-dev \
    && docker-php-ext-install -j"$(nproc)" mbstring sockets bcmath \
    && a2enmod rewrite headers \
    && rm -rf /var/lib/apt/lists/*

# Apache di port 8080 sesuai kontrak/README.md, dokumen root di public/
RUN sed -i 's/Listen 80/Listen 8080/' /etc/apache2/ports.conf \
    && sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' /etc/apache2/sites-available/000-default.conf \
    && sed -i 's#/var/www/html#/var/www/html/public#g' /etc/apache2/sites-available/000-default.conf \
    && printf '<Directory /var/www/html/public>\n    AllowOverride All\n    Require all granted\n</Directory>\n' > /etc/apache2/conf-enabled/pencarian.conf

COPY --from=composer /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html
COPY composer.json ./
RUN composer install --no-interaction --no-progress --prefer-dist

COPY . .
RUN composer dump-autoload --optimize

EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --retries=6 \
    CMD php -r "exit(@file_get_contents('http://127.0.0.1:8080/sehat') === false ? 1 : 0);"

# indeks dibuat dulu (menunggu OpenSearch, tidak fatal bila gagal), lalu Apache
CMD ["sh", "-c", "php bin/siapkan_indeks.php; exec apache2-foreground"]
