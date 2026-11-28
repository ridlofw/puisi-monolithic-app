#!/bin/sh
# Menyalakan node Redis atau Redis Sentinel. Pemakaian: mulai.sh node|sentinel <nama-host-sendiri>
# Master saat ini dicari dulu, supaya node yang menyala ulang bergabung sebagai replika, bukan menjadi master kedua.
set -eu

PERAN="$1"
SAYA="$2"
NAMA="${REDIS_MASTER_NAME:-puisi}"
NODE="${REDIS_NODE:-redis-1 redis-2 redis-3}"
SENTINEL="${REDIS_SENTINEL:-redis-sentinel-1 redis-sentinel-2 redis-sentinel-3}"
MAKSMEM="${REDIS_MAXMEMORY:-128mb}"

peran() {
    timeout 2 redis-cli -h "$1" -p 6379 --raw ROLE 2>/dev/null | head -n 1 || true
}

# master menurut Sentinel lain (diikuti walau sedang mati, Sentinel yang memperbaikinya), atau node yang sedang master
cari_master() {
    for s in $SENTINEL; do
        [ "$s" = "$SAYA" ] && continue
        m=$(timeout 2 redis-cli -h "$s" -p 26379 --raw SENTINEL get-master-addr-by-name "$NAMA" 2>/dev/null | head -n 1 || true)
        if [ -n "$m" ]; then
            echo "$m"
            return
        fi
    done
    for n in $NODE; do
        [ "$n" = "$SAYA" ] && continue
        if [ "$(peran "$n")" = "master" ]; then
            echo "$n"
            return
        fi
    done
}

PERTAMA=$(echo "$NODE" | awk '{print $1}')

if [ "$PERAN" = "node" ]; then
    MASTER=$(cari_master)
    if [ "$MASTER" = "$SAYA" ]; then
        # Sentinel masih menganggap node ini master
        MASTER=""
    elif [ -z "$MASTER" ] && [ "$SAYA" != "$PERTAMA" ]; then
        # klaster baru: node pertama menjadi master, sisanya mengikutinya
        MASTER="$PERTAMA"
    fi
    set -- redis-server --save "" --appendonly no --maxmemory "$MAKSMEM" --maxmemory-policy allkeys-lru \
        --replica-announce-ip "$SAYA" --replica-announce-port 6379
    if [ -n "$MASTER" ]; then
        echo "mulai.sh: $SAYA menjadi replika dari $MASTER"
        exec "$@" --replicaof "$MASTER" 6379
    fi
    echo "mulai.sh: $SAYA menjadi master"
    exec "$@"
fi

# Sentinel menulis ulang berkas konfigurasinya, jadi selalu dibuat baru di /tmp, bukan berkas dari repositori
MASTER=""
i=0
while [ -z "$MASTER" ] && [ "$i" -lt 60 ]; do
    MASTER=$(cari_master)
    if [ -z "$MASTER" ] && [ "$(peran "$PERTAMA")" = "master" ]; then
        MASTER="$PERTAMA"
    fi
    [ -z "$MASTER" ] && sleep 1
    i=$((i + 1))
done
MASTER="${MASTER:-$PERTAMA}"
echo "mulai.sh: $SAYA memantau master $MASTER"
cat > /tmp/sentinel.conf <<EOF
port 26379
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel announce-ip $SAYA
sentinel announce-port 26379
sentinel monitor $NAMA $MASTER 6379 2
sentinel down-after-milliseconds $NAMA ${SENTINEL_DOWN_MS:-3000}
sentinel failover-timeout $NAMA 10000
sentinel parallel-syncs $NAMA 1
EOF
exec redis-server /tmp/sentinel.conf --sentinel
