#!/usr/bin/env bash
# deploy/aws/bangun2.sh : membangun 2 image yang TIDAK dibangun bangun6.sh: pencarian dan text-to-speech (tts).
# Dijalankan di server 1 oleh 9server.sh (image2). Hasilnya didorong ke registry localhost:5000 (Jalur B). Log per image ada di logs/.
#
# Catatan:
#  - puisi-tts memakai AKAR repositori sebagai konteks build (Dockerfile menyalin workers/_templat dan workers/text-to-speech),
#    dan MENGUNDUH model suara Piper (sekitar 60 MB) dari huggingface.co. Server butuh akses internet keluar (ada).
#  - Dockerfile tts menjalankan unit test sebagai CMD bawaan; di stack, perintahnya diganti (python worker.py).
cd /opt/puisi || exit 1
R=localhost:5000; T="${TAG:-v4}"
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
b puisi-pencarian services/pencarian/Dockerfile       services/pencarian
b puisi-tts       workers/text-to-speech/Dockerfile   .
echo "[$(date +%T)] SELESAI"
