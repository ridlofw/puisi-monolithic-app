FROM php:8.3-apache

RUN apt-get update && apt-get install -y --no-install-recommends libonig-dev \
    && docker-php-ext-install -j"$(nproc)" mbstring pdo pdo_mysql \
    && sed -i 's/Listen 80/Listen 8080/' /etc/apache2/ports.conf \
    && sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' /etc/apache2/sites-available/000-default.conf \
    && sed -i 's#/var/www/html#/var/www/html/public#g' /etc/apache2/sites-available/000-default.conf \
    && a2enmod rewrite \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html
COPY public/ ./public/
COPY src/ ./src/

EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --retries=6 \
    CMD php -r "exit(@file_get_contents('http://127.0.0.1:8080/sehat') === false ? 1 : 0);"
