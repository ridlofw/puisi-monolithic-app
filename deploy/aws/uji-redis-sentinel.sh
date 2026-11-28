#!/usr/bin/env bash
# deploy/aws/uji-redis-sentinel.sh : uji failover Redis Sentinel di Docker Swarm, dijalankan di SERVER 1 (manager Swarm) oleh
# `bash 9server.sh ujiredis`. Tidak mematikan server; hanya layanan Redis yang sedang master yang di-scale ke 0 lalu ke 1.
#
#   1. baca master menurut redis-sentinel-1
#   2. mulai probe GET /api/puisi lewat gateway lokal sekali per detik (DETIK, bawaan 120)
#   3. docker service scale puisi_<master>=0, tunggu Sentinel memilih master baru (maks 60 detik), cetak lamanya
#   4. periksa ketiga Sentinel (master sama, tilt 0)
#   5. docker service scale puisi_<master lama>=1, tunggu node lama menjadi REPLIKA (redis/mulai.sh bertanya ke Sentinel dulu)
#   6. ringkasan probe dan baris log Sentinel (sdown, odown, switch-master, tilt)
#
# Semua pertanyaan ke Redis dikirim dari container redis-sentinel-1 (server 1) lewat nama layanan di jaringan overlay.
set -u
S="$(docker ps -qf name=puisi_redis-sentinel-1.)"
[ -n "$S" ] || { echo "[GAGAL] redis-sentinel-1 tidak berjalan di server ini"; exit 1; }
rc() { docker exec "$S" redis-cli "$@" 2>&1 | tr -d '\r'; }
master() { rc -h redis-sentinel-1 -p 26379 SENTINEL get-master-addr-by-name puisi | head -1; }
peran() { rc -h "$1" -p 6379 ROLE | head -1; }
jam() { date -u +%T; }

LAMA="$(master)"
echo "$(jam) master awal menurut redis-sentinel-1: $LAMA"
case "$LAMA" in redis-1|redis-2|redis-3) ;; *) echo "[GAGAL] master tidak terbaca: '$LAMA'"; exit 1 ;; esac

PROBE=/tmp/probe-redis.txt; : > "$PROBE"
(
  akhir=$((SECONDS + ${DETIK:-120}))
  while [ "$SECONDS" -lt "$akhir" ]; do
    printf '%s %s\n' "$(jam)" "$(curl -s -o /dev/null -m 4 -w '%{http_code}' http://127.0.0.1/api/puisi)" >> "$PROBE"
    sleep 1
  done
) &
PID=$!
sleep 3

T0=$(date +%s)
echo "$(jam) docker service scale puisi_$LAMA=0"
docker service scale --detach "puisi_$LAMA=0" >/dev/null
BARU=""
for _ in $(seq 1 60); do
  m="$(master)"
  if [ -n "$m" ] && [ "$m" != "$LAMA" ]; then BARU="$m"; break; fi
  sleep 1
done
T1=$(date +%s)
if [ -n "$BARU" ]; then
  echo "$(jam) master baru menurut redis-sentinel-1: $BARU ($((T1 - T0)) detik sesudah scale 0)"
else
  echo "[GAGAL] tidak ada master baru dalam 60 detik"
fi
sleep 5
for t in redis-sentinel-1 redis-sentinel-2 redis-sentinel-3; do
  echo "$t: master=$(rc -h "$t" -p 26379 SENTINEL get-master-addr-by-name puisi | head -1) $(rc -h "$t" -p 26379 INFO sentinel | grep -E '^sentinel_tilt:')"
done
[ -n "$BARU" ] && echo "peran $BARU: $(peran "$BARU")"

echo "$(jam) docker service scale puisi_$LAMA=1 (node lama harus kembali sebagai REPLIKA)"
docker service scale --detach "puisi_$LAMA=1" >/dev/null
r=""
for _ in $(seq 1 45); do
  r="$(peran "$LAMA")"
  [ "$r" = slave ] && break
  sleep 2
done
echo "$(jam) peran $LAMA sekarang: ${r:-tidak terjangkau}"
sleep 5
for n in redis-1 redis-2 redis-3; do
  echo "$n: $(rc -h "$n" -p 6379 INFO replication | grep -E '^(role|connected_slaves|master_host|master_link_status):' | tr '\n' ' ')"
done
docker service logs --raw puisi_$LAMA 2>&1 | grep 'mulai.sh' | tail -2

wait "$PID"
TOTAL=$(wc -l < "$PROBE"); BURUK=$(awk '$2 != "200"' "$PROBE" | wc -l)
echo "probe GET /api/puisi sekali per detik: $TOTAL, bukan 200: $BURUK"
awk '$2 != "200"' "$PROBE" | head -10
echo "---- log Sentinel (sdown, odown, switch-master, tilt) ----"
docker service logs --since 10m --raw puisi_redis-sentinel-1 2>&1 | grep -E 'sdown|odown|switch-master|tilt' | cut -c1-160 | tail -12
