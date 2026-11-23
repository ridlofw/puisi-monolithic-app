FROM nginx:alpine

# keepalived menjaga satu virtual IP berpindah ke gateway cadangan bila gateway utama mati (Bab 11.5.1)
RUN apk add --no-cache keepalived

COPY ha/keepalived.conf.tmpl /etc/keepalived/keepalived.conf.tmpl
COPY ha/cek_nginx.sh /etc/keepalived/cek_nginx.sh
COPY ha/entrypoint.sh /ha-entrypoint.sh
RUN chmod 755 /etc/keepalived/cek_nginx.sh /ha-entrypoint.sh

ENTRYPOINT ["/ha-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
