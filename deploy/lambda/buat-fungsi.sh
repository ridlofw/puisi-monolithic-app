#!/usr/bin/env bash
# Membuat (atau memperbarui) fungsi AWS Lambda gambar puisi dari folder lambda/ (Hands-on 1)
# dan membuka Function URL-nya. Jalankan di tempat yang punya AWS CLI + Node.js + zip dan
# kredensial sandbox: AWS CloudShell (AWS CLI sudah terpasang dan kredensial sandbox sudah terisi).
#
#   export BUCKET_NAME=nama-bucket-s3-kelompok     # WAJIB: bucket berisi latar1.jpeg dst.
#   bash deploy/lambda/buat-fungsi.sh
#
# Variabel opsional: AWS_REGION (bawaan: region konfigurasi AWS CLI), FUNCTION_NAME
# (bawaan puisi-gambar), ROLE_ARN (bawaan: LabRole di akun ini), RUNTIME (bawaan nodejs24.x).
#
# RUNTIME: nodejs24.x sama dengan Hands-on 1 ("Node.js 24.x"). nodejs20.x sudah deprecated sejak 30 April 2026
# (https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html), jadi jangan dipakai. Bila AWS CLI Anda
# menolak nodejs24.x, jalankan: RUNTIME=nodejs22.x bash deploy/lambda/buat-fungsi.sh
#
# STATUS (23 November 2026): kode fungsi dan paket function.zip (19 MB) sudah diuji di LAPTOP (Node 24):
# preview menghasilkan JPEG, template hilang memberi 500, dan paket yang di-unzip bisa dijalankan. Itu memakai
# S3 palsu. Skrip ini sendiri (panggilan aws lambda ...) BELUM pernah dijalankan di AWS. Pengaturan izin
# Function URL berubah di AWS dari waktu ke waktu; bila langkah izin gagal atau URL menjawab 403,
# lihat deploy/lambda/README.md bagian "Bila gagal".
set -euo pipefail

: "${BUCKET_NAME:?isi BUCKET_NAME dengan nama bucket S3 Anda}"
FUNCTION_NAME="${FUNCTION_NAME:-puisi-gambar}"
RUNTIME="${RUNTIME:-nodejs24.x}"
REGION="${AWS_REGION:-$(aws configure get region || true)}"
: "${REGION:?isi AWS_REGION atau jalankan: aws configure set region <kode-region>}"

AKUN="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="${ROLE_ARN:-arn:aws:iam::${AKUN}:role/LabRole}"

cd "$(dirname "$0")/../../lambda"
echo "=== memasang dependensi dan membuat function.zip ==="
npm install --omit=dev
rm -f function.zip
zip -qr function.zip index.mjs package.json node_modules
ls -lh function.zip

if aws lambda get-function --region "$REGION" --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
  echo "=== memperbarui kode fungsi $FUNCTION_NAME ==="
  aws lambda update-function-code --region "$REGION" --function-name "$FUNCTION_NAME" \
    --zip-file fileb://function.zip >/dev/null
  aws lambda wait function-updated --region "$REGION" --function-name "$FUNCTION_NAME"
  aws lambda update-function-configuration --region "$REGION" --function-name "$FUNCTION_NAME" \
    --timeout 15 --memory-size 512 \
    --environment "Variables={BUCKET_NAME=${BUCKET_NAME}}" >/dev/null
else
  echo "=== membuat fungsi $FUNCTION_NAME ($RUNTIME, role $ROLE_ARN) ==="
  aws lambda create-function --region "$REGION" --function-name "$FUNCTION_NAME" \
    --runtime "$RUNTIME" --handler index.handler --role "$ROLE_ARN" \
    --timeout 15 --memory-size 512 \
    --environment "Variables={BUCKET_NAME=${BUCKET_NAME}}" \
    --zip-file fileb://function.zip >/dev/null
  aws lambda wait function-active --region "$REGION" --function-name "$FUNCTION_NAME"
fi

echo "=== Function URL (auth NONE, dipanggil CloudFront dari internet) ==="
if ! aws lambda get-function-url-config --region "$REGION" --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
  aws lambda create-function-url-config --region "$REGION" --function-name "$FUNCTION_NAME" \
    --auth-type NONE >/dev/null
fi
# Izin publik. AWS meminta DUA izin untuk Function URL baru; masing-masing boleh sudah ada.
aws lambda add-permission --region "$REGION" --function-name "$FUNCTION_NAME" \
  --statement-id url-publik-1 --action lambda:InvokeFunctionUrl --principal '*' \
  --function-url-auth-type NONE >/dev/null 2>&1 || echo "(izin InvokeFunctionUrl sudah ada atau ditolak)"
aws lambda add-permission --region "$REGION" --function-name "$FUNCTION_NAME" \
  --statement-id url-publik-2 --action lambda:InvokeFunction --principal '*' \
  --invoked-via-function-url >/dev/null 2>&1 || echo "(izin InvokeFunction sudah ada, atau CLI Anda belum mengenal --invoked-via-function-url)"

URL="$(aws lambda get-function-url-config --region "$REGION" --function-name "$FUNCTION_NAME" \
        --query FunctionUrl --output text)"
echo
echo "Selesai."
echo "  Function URL : $URL"
echo "  Uji preview  : curl -s -o /tmp/uji.jpg -w '%{http_code}\n' \"${URL}?action=preview&template=latar1.jpeg&judul=Uji&penulis=Ridlo&kutipan=halo\""
echo "  Lanjut       : deploy/lambda/README.md (CloudFront, lalu CDN_URL untuk image gateway)"
