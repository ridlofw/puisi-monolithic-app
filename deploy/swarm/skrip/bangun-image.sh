#!/usr/bin/env bash
# Membangun (dan mendorong) 8 image yang dipakai stack.yaml.
# JALANKAN DI SERVER EC2, bukan di laptop: jaringan laptop sekitar 0,35 MB/s, sedangkan
# image berukuran sekitar 3,8 GB (mendorongnya dari laptop bisa memakan jam).
#
# Dari akar repositori, di server manager:
#   # Jalur A: ECR (bila tersedia di sandbox, BELUM diverifikasi)
#   export AWS_REGION=<region sandbox>
#   export REGISTRY=<akun>.dkr.ecr.$AWS_REGION.amazonaws.com
#   ECR=1 bash deploy/swarm/skrip/bangun-image.sh
#
#   # Jalur B: registry sendiri di Swarm (tanpa ECR). Deploy dulu stack.registry.yaml,
#   # REGISTRY dibiarkan localhost:5000.
#   bash deploy/swarm/skrip/bangun-image.sh
#
# Variabel: REGISTRY (bawaan localhost:5000), TAG (bawaan v1), ECR=1 (buat repositori
# ECR dan login lebih dulu; butuh AWS CLI dan izin ECR pada instance profile).
set -euo pipefail

cd "$(dirname "$0")/../../.."   # akar repositori

REGISTRY="${REGISTRY:-localhost:5000}"
TAG="${TAG:-v1}"
IMAGES=(puisi-gateway puisi-poem puisi-auth puisi-pencarian puisi-auto-tagging \
        puisi-klasifikasi-genre puisi-analisis-emosi puisi-tts)

if [ "${ECR:-0}" = "1" ]; then
  : "${AWS_REGION:?isi AWS_REGION}"
  for nama in "${IMAGES[@]}"; do
    aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$nama" >/dev/null 2>&1 \
      || aws ecr create-repository --region "$AWS_REGION" --repository-name "$nama" >/dev/null
  done
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "${REGISTRY%%/*}"
fi

bangun() {  # bangun <nama image> <Dockerfile> <konteks> [argumen docker build tambahan]
  echo "=== membangun $1 ==="
  local nama="$1" berkas="$2" konteks="$3"; shift 3
  docker build "$@" -f "$berkas" -t "$REGISTRY/$nama:$TAG" "$konteks"
}

# CDN_URL (opsional): alamat CloudFront gambar kutipan (Lambda, lihat deploy/lambda/README.md).
# Tanpa ini fitur gambar kutipan mati. ECR=1 CDN_URL=https://dxxxx.cloudfront.net bash ...
bangun puisi-gateway           deploy/swarm/Dockerfile.gateway               . --build-arg "CDN_URL=${CDN_URL:-}"
bangun puisi-poem              services/puisi/Dockerfile                     services/puisi
bangun puisi-auth              services/auth/Dockerfile                      services/auth
bangun puisi-pencarian         services/pencarian/Dockerfile                 services/pencarian
bangun puisi-auto-tagging      workers/auto-tagging/Dockerfile               workers/auto-tagging
bangun puisi-klasifikasi-genre workers/klasifikasi-genre/Dockerfile          workers/klasifikasi-genre
bangun puisi-analisis-emosi    workers/analisis-emosi/Dockerfile             workers/analisis-emosi
bangun puisi-tts               workers/text-to-speech/Dockerfile             .   # konteks akar repositori, sama seperti compose/text-to-speech.yaml

for nama in "${IMAGES[@]}"; do
  echo "=== mendorong $nama ==="
  docker push "$REGISTRY/$nama:$TAG"
done

echo
echo "Selesai. Deploy dengan:"
echo "  REGISTRY=$REGISTRY TAG=$TAG docker stack deploy -c deploy/swarm/stack.yaml --with-registry-auth puisi"
