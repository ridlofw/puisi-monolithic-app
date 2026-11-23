#!/bin/sh
set -eu

# tanpa GW_VIP gateway berjalan seperti nginx biasa, misalnya saat hanya satu gateway dinyalakan
if [ -n "${GW_VIP:-}" ]; then
    antarmuka=$(ip -o -4 addr show | awk -v ip="$GW_SELF" '$4 ~ "^"ip"/" {print $2; exit}')
    if [ -z "$antarmuka" ]; then
        echo "[gateway-ha] antarmuka dengan IP $GW_SELF tidak ditemukan" >&2
        exit 1
    fi
    sed -e "s/NAMA/${GW_NAMA:-gateway}/" \
        -e "s/STATUS/${GW_STATUS:-BACKUP}/" \
        -e "s/ANTARMUKA/$antarmuka/g" \
        -e "s/PRIORITAS/${GW_PRIORITAS:-100}/" \
        -e "s/IP_SENDIRI/$GW_SELF/" \
        -e "s/IP_PASANGAN/$GW_PEER/" \
        -e "s/VIP/$GW_VIP/" \
        /etc/keepalived/keepalived.conf.tmpl > /etc/keepalived/keepalived.conf
    keepalived --use-file /etc/keepalived/keepalived.conf --log-console --dont-fork &
    echo "[gateway-ha] keepalived ${GW_STATUS:-BACKUP} prioritas ${GW_PRIORITAS:-100}, VIP $GW_VIP di $antarmuka"
fi

exec /docker-entrypoint.sh "$@"
