#!/usr/bin/env bash
# deploy/aws/bangun6.sh : membangun dan mendorong 6 image tahap 1 (pencarian dan tts dibangun terpisah oleh bangun2.sh, tahap 2)
# ke registry localhost:5000 (Jalur B). Dijalankan di server 1 oleh 9server.sh. Log per image ada di logs/.
# CDN_URL (opsional) dimasukkan ke image gateway.
cd /opt/puisi || exit 1
R=localhost:5000; T="${TAG:-v1}"
mkdir -p logs
b() {  # b <nama> <Dockerfile> <konteks> [argumen build tambahan]
  local n="$1" f="$2" ctx="$3"; shift 3
  echo "[$(date +%T)] bangun $n"
  if docker build "$@" -f "$f" -t "$R/$n:$T" "$ctx" > "logs/$n.log" 2>&1 && docker push "$R/$n:$T" >> "logs/$n.log" 2>&1; then
    echo "[$(date +%T)] OK    $n"
  else
    echo "[$(date +%T)] GAGAL $n (lihat logs/$n.log)"; tail -5 "logs/$n.log" | sed 's/^/      /'
  fi
}
b puisi-gateway           deploy/swarm/Dockerfile.gateway          .                          --build-arg "CDN_URL=${CDN_URL:-}"
b puisi-poem              services/puisi/Dockerfile                services/puisi
b puisi-auth              services/auth/Dockerfile                 services/auth
b puisi-auto-tagging      workers/auto-tagging/Dockerfile          workers/auto-tagging
b puisi-klasifikasi-genre workers/klasifikasi-genre/Dockerfile     workers/klasifikasi-genre
b puisi-analisis-emosi    workers/analisis-emosi/Dockerfile        workers/analisis-emosi
echo "[$(date +%T)] SELESAI"
