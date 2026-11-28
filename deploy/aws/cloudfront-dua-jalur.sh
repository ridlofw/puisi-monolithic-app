#!/usr/bin/env bash
# deploy/aws/cloudfront-dua-jalur.sh : CloudFront yang MEMECAH lalu lintas menjadi jalur-jalur terpisah (satu alamat HTTPS):
#
#   /                  halaman (index.html, style.css, js/*)  ->  S3 (statis, di-cache CloudFront; server TIDAK ikut melayani)
#   /latar*.jpeg       gambar latar                           ->  S3 (bucket yang sama)
#   /fungsi*           gambar kutipan                         ->  Lambda (Function URL)
#   /api/*             API (auth, puisi, pencarian)           ->  ALB -> gateway -> layanan di server  (tanpa cache)
#   /audio/*           berkas suara hasil text-to-speech      ->  ALB -> gateway -> SeaweedFS          (di-cache)
#
# Dibanding https-cloudfront.sh (satu asal: semuanya lewat ALB), di sini hanya /api dan /audio yang menyentuh server.
# Halaman, JS, CSS, dan gambar dilayani dari S3/CloudFront, jadi beban server hanya pekerjaan aplikasi yang sebenarnya.
#
#   bash cloudfront-dua-jalur.sh buat      # distribusi baru + unggah web/ ke S3 + uji
#   bash cloudfront-dua-jalur.sh unggah    # unggah ulang web/ (setelah frontend diubah); terlihat paling lama 60 detik kemudian
#   bash cloudfront-dua-jalur.sh status
#   YA=1 bash cloudfront-dua-jalur.sh hapus
#
# Prasyarat (semuanya sudah ada setelah langkah-langkah sebelumnya di docs/PANDUAN-DEPLOY-AWS.md):
#   ~/.puisi-gambar.state     dari deploy/lambda/siapkan-gambar.sh (bucket S3 publik, Function URL Lambda, kebijakan cache)
#   ~/puisi9/alb-dns          dari deploy/aws/alb.sh buat
#   WEB_DIR (bawaan ~/puisi9/web)  isi folder web/ dari repositori. Cara mengambilnya dari arsip kode:
#                                  mkdir -p ~/puisi9 && tar xzf ~/kode.tgz -C ~/puisi9 web
#
# FRONTEND TIDAK DIUBAH di repositori. web/js/api.js menyimpan `cdn: ''`, dan kirim.js MEMATIKAN fitur gambar bila kosong. Saat unggah,
# skrip ini menyisipkan alamat distribusi ke SALINAN api.js yang diunggah (cara yang sama dengan deploy/swarm/Dockerfile.gateway).
# Karena alamatnya sama dengan alamat halaman, tidak ada lintas-asal (CORS) dan token login tetap satu asal.
#
# YANG DIKETAHUI: batas login 10 per menit di gateway dihitung per IP; di belakang CloudFront IP yang terbaca adalah IP edge
# (perbaikannya: deploy/swarm/gateway/buat-cloudfront-conf.sh, lalu bangun ulang image gateway). ALB masih bisa dijangkau langsung lewat HTTP.
export AWS_PAGER=""
REGION="${AWS_REGION:-us-east-1}"
W="${W_DIR:-$HOME/puisi9}"   # versi Single memakai W_DIR=~/puisi1 dan alb-dns berisi alamat server tunggal (deploy/aws/1server.sh cloudfront)
STATE="${STATE_FILE:-$HOME/.puisi-gambar.state}"
WEB_DIR="${WEB_DIR:-$W/web}"
MODE="${1:-buat}"
ID_CP_CACHING_DISABLED="4135ea2d-6df8-44a3-9df3-4b5a84be39ad"       # Managed-CachingDisabled
ID_CP_CACHING_OPTIMIZED="658327ea-f89d-4fab-a63d-7e88639e58f6"      # Managed-CachingOptimized
ID_ORP_ALLVIEWER="216adef6-5c7f-47e4-b989-5492eafa07d3"              # Managed-AllViewer (untuk ALB; meneruskan Host, Authorization, dst.)
ID_ORP_ALLVIEWER_TANPA_HOST="b689b0a8-53d0-40ab-baf2-68738e2966ac"   # Managed-AllViewerExceptHostHeader (untuk Lambda)
CP_STATIS_NAMA="puisi-StatisPendek"

bersih() {
  sed -u -E \
    -e 's#(assumed-role|user|role)/([A-Za-z0-9+=,.@_-]+)/[^[:space:]"]+#\1/\2/<sesi>#g' \
    -e 's/user[0-9]+=[^"[:space:],]+/<sesi>/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
    -e 's/[0-9]{12}/<akun>/g'
}
gagal() { echo "[GAGAL] $*"; exit 1; }
guna() { [ -f "$STATE" ] && grep -E "^$1=" "$STATE" | tail -1 | cut -d= -f2-; }
pilih_python() { local p; for p in python3 python; do if "$p" -c 'import json' >/dev/null 2>&1; then echo "$p"; return; fi; done; }
cari_kebijakan() { # cari_kebijakan <cache|origin> <nama bawaan> <id cadangan>
  local id=""
  if [ "$1" = cache ]; then
    id="$(aws cloudfront list-cache-policies --type managed --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='$2'].CachePolicy.Id | [0]" --output text 2>/dev/null)"
  else
    id="$(aws cloudfront list-origin-request-policies --type managed --query "OriginRequestPolicyList.Items[?OriginRequestPolicy.OriginRequestPolicyConfig.Name=='$2'].OriginRequestPolicy.Id | [0]" --output text 2>/dev/null)"
  fi
  if [ -z "$id" ] || [ "$id" = "None" ]; then echo "(kebijakan $2 tidak ditemukan lewat nama; memakai ID dokumentasi)" >&2; id="$3"; fi
  echo "$id"
}

# kebijakan cache khusus berkas statis: TTL bawaan 60 detik (supaya unggah ulang cepat terlihat), tanpa query string/header/cookie
buat_kebijakan_statis() {
  local id; id="$(aws cloudfront list-cache-policies --type custom --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='$CP_STATIS_NAMA'].CachePolicy.Id | [0]" --output text 2>/dev/null)"
  if [ -n "$id" ] && [ "$id" != "None" ]; then echo "$id"; return; fi
  local J; J="$(mktemp)"
  cat > "$J" <<EOF
{"Name":"$CP_STATIS_NAMA","Comment":"berkas statis dari S3: TTL 60 detik, tanpa query string/header/cookie","DefaultTTL":60,"MaxTTL":300,"MinTTL":0,
 "ParametersInCacheKeyAndForwardedToOrigin":{"EnableAcceptEncodingGzip":true,"EnableAcceptEncodingBrotli":true,
  "HeadersConfig":{"HeaderBehavior":"none"},"CookiesConfig":{"CookieBehavior":"none"},"QueryStringsConfig":{"QueryStringBehavior":"none"}}}
EOF
  aws cloudfront create-cache-policy --cache-policy-config "file://$J" --query CachePolicy.Id --output text 2>"$W/err.txt" \
    || gagal "create-cache-policy: $(head -c 300 "$W/err.txt")"
}

# tulis_json <berkas> <host-s3-website> <host-alb> <host-lambda> <cp-statis> <cp-fungsi> <cp-disabled> <cp-optimized> <orp-alb> <orp-lambda>
tulis_json() {
  cat > "$1" <<EOF
{
  "CallerReference": "puisi-dua-jalur-$(date +%s)",
  "Comment": "puisi: halaman dari S3, /api dan /audio ke ALB, /fungsi ke Lambda (dibuat cloudfront-dua-jalur.sh)",
  "Enabled": true,
  "PriceClass": "PriceClass_100",
  "HttpVersion": "http2",
  "IsIPV6Enabled": true,
  "DefaultRootObject": "index.html",
  "Origins": {"Quantity": 3, "Items": [
    {"Id": "s3-website", "DomainName": "$2",
     "CustomOriginConfig": {"HTTPPort": 80, "HTTPSPort": 443, "OriginProtocolPolicy": "http-only",
       "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}}},
    {"Id": "alb", "DomainName": "$3",
     "CustomOriginConfig": {"HTTPPort": 80, "HTTPSPort": 443, "OriginProtocolPolicy": "http-only",
       "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}, "OriginReadTimeout": 30, "OriginKeepaliveTimeout": 5}},
    {"Id": "lambda-url", "DomainName": "$4",
     "CustomOriginConfig": {"HTTPPort": 80, "HTTPSPort": 443, "OriginProtocolPolicy": "https-only",
       "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}}}
  ]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-website",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"], "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}},
    "Compress": true,
    "CachePolicyId": "$5"
  },
  "CacheBehaviors": {"Quantity": 3, "Items": [
    {"PathPattern": "/api/*",
     "TargetOriginId": "alb",
     "ViewerProtocolPolicy": "redirect-to-https",
     "AllowedMethods": {"Quantity": 7, "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
                        "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}},
     "Compress": true,
     "CachePolicyId": "$7",
     "OriginRequestPolicyId": "$9"},
    {"PathPattern": "/audio/*",
     "TargetOriginId": "alb",
     "ViewerProtocolPolicy": "redirect-to-https",
     "AllowedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"], "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}},
     "Compress": false,
     "CachePolicyId": "$8"},
    {"PathPattern": "/fungsi*",
     "TargetOriginId": "lambda-url",
     "ViewerProtocolPolicy": "redirect-to-https",
     "AllowedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"], "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}},
     "Compress": false,
     "CachePolicyId": "$6",
     "OriginRequestPolicyId": "${10}"}
  ]}
}
EOF
}

# uji <url> <kode-harapan> [teks-yang-harus-ada-di-isi] [argumen curl...]
uji() {
  local url="$1" harap="$2" teks="${3:-}" k i b; shift 2; [ $# -gt 0 ] && shift
  for i in 1 2 3 4 5 6; do
    if [ -n "$teks" ]; then   # hanya berkas teks yang isinya dibaca; gambar (biner) cukup diperiksa kode HTTP-nya
      b="$(curl -s -m 20 -w '\n%{http_code}' "$@" "$url" 2>/dev/null)"; k="$(echo "$b" | tail -1)"
    else
      k="$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$@" "$url" 2>/dev/null)"; b=""
    fi
    if [ "$k" = "$harap" ] && { [ -z "$teks" ] || echo "$b" | grep -q -- "$teks"; }; then echo "[OK] $k  <- $url"; return 0; fi
    sleep 8
  done
  echo "[GAGAL] jawaban terakhir $k (harapan $harap${teks:+, isi memuat '$teks'})  <- $url"; return 1
}

# unggah_web <domain>: salin web/ ke bucket, dengan alamat distribusi disisipkan ke api.js
unggah_web() {
  local DOM="$1" B T; B="$(guna BUCKET_NAME)"
  [ -n "$B" ] || gagal "BUCKET_NAME tidak ada di $STATE (jalankan deploy/lambda/siapkan-gambar.sh dulu)"
  [ -f "$WEB_DIR/index.html" ] || gagal "$WEB_DIR/index.html tidak ada. Ambil dari arsip: mkdir -p ~/puisi9 && tar xzf ~/kode.tgz -C ~/puisi9 web"
  T="$(mktemp -d)"; cp -r "$WEB_DIR/." "$T/"
  sed -i "s|cdn: '',|cdn: 'https://$DOM',|" "$T/js/api.js"
  grep -q "cdn: 'https://$DOM'," "$T/js/api.js" || gagal "gagal menyisipkan alamat ke js/api.js (apakah baris \`cdn: '',\` masih ada?)"
  aws s3 sync "$T" "s3://$B/" --cache-control "max-age=60" --exclude "latar*" --no-progress 2>"$W/err.txt" | sed 's/^/  /' || gagal "s3 sync: $(head -c 300 "$W/err.txt")"
  rm -rf "$T"
  echo "[OK] web/ diunggah ke s3://$B/ (alamat di api.js: https://$DOM)"
}

buat() {
  if [ "${JSON_SAJA:-}" = "1" ]; then   # mode uji offline: hanya menulis JSON
    tulis_json "${JSON_KELUAR:-/tmp/dist-dua.json}" "contoh.s3-website-us-east-1.amazonaws.com" "contoh-alb.us-east-1.elb.amazonaws.com" "contoh.lambda-url.us-east-1.on.aws" \
      "aaaa1111-0000-0000-0000-000000000001" "aaaa1111-0000-0000-0000-000000000002" "$ID_CP_CACHING_DISABLED" "$ID_CP_CACHING_OPTIMIZED" "$ID_ORP_ALLVIEWER" "$ID_ORP_ALLVIEWER_TANPA_HOST"
    echo "JSON ditulis ke ${JSON_KELUAR:-/tmp/dist-dua.json}"; return 0
  fi
  command -v aws >/dev/null 2>&1 || gagal "aws tidak ditemukan; jalankan di AWS CloudShell"
  local B ALB FURL LHOST S3HOST cand
  B="$(guna BUCKET_NAME)"; [ -n "$B" ] || gagal "BUCKET_NAME tidak ada di $STATE (jalankan deploy/lambda/siapkan-gambar.sh dulu)"
  FURL="$(guna FUNCTION_URL)"; [ -n "$FURL" ] || gagal "FUNCTION_URL tidak ada di $STATE"
  LHOST="${FURL#https://}"; LHOST="${LHOST%/}"
  ALB="$(cat "$W/alb-dns" 2>/dev/null)"; [ -n "$ALB" ] || gagal "belum ada ~/puisi9/alb-dns (jalankan alb.sh buat)"
  [ -f "$WEB_DIR/index.html" ] || gagal "$WEB_DIR/index.html tidak ada. Ambil dari arsip: mkdir -p ~/puisi9 && tar xzf ~/kode.tgz -C ~/puisi9 web"

  # index.html harus ada di bucket SEBELUM titik akhir website diuji; alamat distribusi menyusul (unggah ulang setelah distribusi jadi)
  aws s3 cp "$WEB_DIR/index.html" "s3://$B/index.html" --cache-control "max-age=60" --no-progress >/dev/null 2>"$W/err.txt" || gagal "unggah index.html: $(head -c 300 "$W/err.txt")"
  for cand in "$B.s3-website-$REGION.amazonaws.com" "$B.s3-website.$REGION.amazonaws.com"; do
    if [ "$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$cand/index.html")" = "200" ]; then S3HOST="$cand"; break; fi
  done
  [ -n "$S3HOST" ] || gagal "titik akhir website S3 tidak menjawab 200 untuk index.html"
  echo "asal S3 website : $S3HOST"; echo "asal ALB        : $ALB"; echo "asal Lambda URL : $LHOST"

  local CP_STAT CP_FUNGSI CP_DIS CP_OPT ORP_ALB ORP_LAMBDA
  CP_STAT="$(buat_kebijakan_statis)"; CP_FUNGSI="$(guna CACHE_POLICY_ID)"
  [ -n "$CP_FUNGSI" ] || gagal "CACHE_POLICY_ID tidak ada di $STATE (dibuat siapkan-gambar.sh)"
  CP_DIS="$(cari_kebijakan cache Managed-CachingDisabled "$ID_CP_CACHING_DISABLED")"
  CP_OPT="$(cari_kebijakan cache Managed-CachingOptimized "$ID_CP_CACHING_OPTIMIZED")"
  ORP_ALB="$(cari_kebijakan origin Managed-AllViewer "$ID_ORP_ALLVIEWER")"
  ORP_LAMBDA="$(cari_kebijakan origin Managed-AllViewerExceptHostHeader "$ID_ORP_ALLVIEWER_TANPA_HOST")"
  echo "kebijakan cache: statis=$CP_STAT fungsi=$CP_FUNGSI api=$CP_DIS audio=$CP_OPT"

  local ID DOM CFJ H
  ID="$(cat "$W/cf-dua-id" 2>/dev/null)"
  if [ -n "$ID" ] && DOM="$(aws cloudfront get-distribution --id "$ID" --query Distribution.DomainName --output text 2>/dev/null)" && [ -n "$DOM" ] && [ "$DOM" != None ]; then
    echo "distribusi $ID sudah ada ($DOM), dipakai ulang"
  else
    CFJ="$(mktemp)"; tulis_json "$CFJ" "$S3HOST" "$ALB" "$LHOST" "$CP_STAT" "$CP_FUNGSI" "$CP_DIS" "$CP_OPT" "$ORP_ALB" "$ORP_LAMBDA"
    H="$(aws cloudfront create-distribution --distribution-config "file://$CFJ" --query '[Distribution.Id,Distribution.DomainName]' --output text 2>"$W/err.txt")" \
      || gagal "create-distribution: $(head -c 500 "$W/err.txt")"
    ID="$(echo "$H" | awk '{print $1}')"; DOM="$(echo "$H" | awk '{print $2}')"
    echo "$ID" > "$W/cf-dua-id"; echo "distribusi $ID dibuat ($DOM)"
  fi
  echo "$DOM" > "$W/cf-dua-dns"
  unggah_web "$DOM"
  echo "menunggu CloudFront selesai (3 sampai 15 menit; jangan ditutup)..."
  aws cloudfront wait distribution-deployed --id "$ID" 2>"$W/err.txt" || echo "[PERHATIAN] 'wait' berhenti: $(head -c 200 "$W/err.txt"); lanjut menguji."

  echo; echo "==== Uji lewat HTTPS ===="
  local lulus=0 total=0 PRIMER; PRIMER="$(grep -oE 'latar[0-9]+\.jpeg' "$WEB_DIR/js/api.js" | head -1)"; PRIMER="${PRIMER:-latar1.jpeg}"
  t() { total=$((total+1)); "$@" && lulus=$((lulus+1)); }
  t uji "https://$DOM/" 200 "Aplikasi Puisi"                                                        # halaman dari S3
  t uji "https://$DOM/js/api.js" 200 "cdn: 'https://$DOM',"                                         # alamat tersisip
  t uji "https://$DOM/style.css" 200
  t uji "https://$DOM/$PRIMER" 200                                                                  # gambar latar dari S3
  t uji "https://$DOM/fungsi?action=preview&template=$PRIMER&judul=Uji&penulis=Skrip&kutipan=halo" 200   # Lambda
  t uji "https://$DOM/api/puisi/sehat" 200                                                          # ALB -> gateway -> poem-service
  t uji "https://$DOM/api/auth/login" 401 "" -X POST -H 'Content-Type: application/json' -d '{"username":"tidak-ada","password":"salah"}'   # POST sampai ke aplikasi
  t uji "http://$DOM/" 301                                                                          # HTTP dialihkan ke HTTPS
  echo; echo "uji lulus: $lulus dari $total"
  echo "ALAMAT APLIKASI (HTTPS): https://$DOM/"
}

status() {
  local ID; ID="$(cat "$W/cf-dua-id" 2>/dev/null)"; [ -n "$ID" ] || gagal "belum ada distribusi dua-jalur"
  aws cloudfront get-distribution --id "$ID" --query '[Distribution.Status,Distribution.DomainName,DistributionConfig.Enabled]' --output text
}

unggah() {
  local DOM; DOM="$(cat "$W/cf-dua-dns" 2>/dev/null)"; [ -n "$DOM" ] || gagal "belum ada distribusi dua-jalur (jalankan buat)"
  unggah_web "$DOM"
}

hapus() {
  [ "${YA:-}" = "1" ] || { echo "Ini menghapus distribusi CloudFront dua-jalur (bucket S3 dan Lambda tidak disentuh). Jalankan: YA=1 bash cloudfront-dua-jalur.sh hapus"; return 0; }
  local ID PY ETAG; ID="$(cat "$W/cf-dua-id" 2>/dev/null)"; [ -n "$ID" ] || { echo "tidak ada yang dihapus"; return 0; }
  PY="$(pilih_python)"; [ -n "$PY" ] || gagal "python tidak ada"
  ETAG="$(aws cloudfront get-distribution-config --id "$ID" --query ETag --output text)" || gagal "get-distribution-config"
  aws cloudfront get-distribution-config --id "$ID" --query DistributionConfig --output json > "$W/cfd.json"
  "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); d['Enabled']=False; json.dump(d,open(sys.argv[2],'w'))" "$W/cfd.json" "$W/cfd-off.json"
  aws cloudfront update-distribution --id "$ID" --if-match "$ETAG" --distribution-config "file://$W/cfd-off.json" >/dev/null || gagal "update-distribution"
  aws cloudfront wait distribution-deployed --id "$ID"
  ETAG="$(aws cloudfront get-distribution --id "$ID" --query ETag --output text)"
  aws cloudfront delete-distribution --id "$ID" --if-match "$ETAG" && echo "distribusi dihapus" && rm -f "$W/cf-dua-id" "$W/cf-dua-dns"
}

set -o pipefail
case "$MODE" in
  buat) buat 2>&1 | bersih ;;
  unggah) unggah 2>&1 | bersih ;;
  status) status 2>&1 | bersih ;;
  hapus) hapus 2>&1 | bersih ;;
  *) echo "Pemakaian: bash cloudfront-dua-jalur.sh [buat|unggah|status|hapus]" ;;
esac
