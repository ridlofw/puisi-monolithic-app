#!/usr/bin/env bash
# deploy/lambda/siapkan-gambar.sh : MEMBUAT SELURUH bagian "gambar kutipan" (Hands-on 1) DALAM SEKALI JALAN:
#
#   1. bucket S3  (+ matikan Block Public Access, bucket policy baca-publik, static website hosting)
#   2. fungsi Lambda puisi-gambar (memanggil buat-fungsi.sh: zip, create-function, Function URL, izin publik)
#   3. berkas latar latar*.jpeg di bucket (milik dosen bila ada; bila tidak ada dibuatkan PENGGANTI SEMENTARA)
#   4. distribusi CloudFront: origin S3 + origin Lambda, behavior /fungsi*, kebijakan cache dan origin request
#   5. uji otomatis (Lambda langsung, lalu lewat CloudFront) dan mencetak CDN_URL
#
# Tidak ada pengaturan manual di console. IAM: TIDAK membuat peran baru (Learner Lab melarang); memakai LabRole.
# Aman diulang: yang sudah dibuat dicatat di ~/.puisi-gambar.state dan dipakai ulang, bukan dibuat dobel.
#
# CARA PAKAI (AWS CloudShell, region sandbox Anda):
#   git clone https://github.com/ridlofw/puisi-monolithic-app.git && cd puisi-monolithic-app
#   (deploy/ belum ada di GitHub: unggah deploy/lambda/*.sh ke deploy/lambda/ lewat Actions, Upload file)
#   mkdir -p latar && (unggah latar1.jpeg latar2.jpeg latar3.jpeg latar5.jpeg dari dosen ke folder latar/, bila ada)
#   bash deploy/lambda/siapkan-gambar.sh            # membuat semuanya
#   YA=1 bash deploy/lambda/siapkan-gambar.sh hapus  # menghapus HANYA yang dibuat skrip ini
#
# Variabel opsional: BUCKET_NAME, FUNCTION_NAME (puisi-gambar), LATAR_DIR (./latar), AWS_REGION, RUNTIME.
#
# STATUS (23 November 2026): sintaks diperiksa; alur diuji dengan "aws" dan "curl" palsu; JSON konfigurasi CloudFront
# divalidasi terhadap model API (botocore) secara offline; pembuatan latar pengganti dijalankan sungguhan di laptop.
# BELUM pernah dijalankan di AWS. Aturan server-side (izin Learner Lab untuk CloudFront/S3 publik) baru terbukti saat dijalankan.
#
# PRIVASI: seluruh keluaran disaring (akun 12 digit, email, nama sesi, ID kunci), karena pesan galat AWS mencetak ARN.
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

DIR="$(cd "$(dirname "$0")" && pwd)"
LAMBDA_DIR="${LAMBDA_DIR:-$DIR/../../lambda}"
API_JS="${API_JS:-$DIR/../../web/js/api.js}"
BUAT_FUNGSI="${BUAT_FUNGSI:-$DIR/buat-fungsi.sh}"
STATE="${STATE_FILE:-$HOME/.puisi-gambar.state}"
FUNCTION_NAME="${FUNCTION_NAME:-puisi-gambar}"
LATAR_DIR="${LATAR_DIR:-$PWD/latar}"
CP_NAME="puisi-CacheWithQueryString"
MODE="${1:-buat}"
# ID kebijakan bawaan CloudFront (https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-origin-request-policies.html)
# dipakai hanya bila pencarian berdasarkan nama gagal.
ID_ORP_ALLVIEWER_TANPA_HOST="b689b0a8-53d0-40ab-baf2-68738e2966ac"
ID_CP_CACHING_OPTIMIZED="658327ea-f89d-4fab-a63d-7e88639e58f6"

bersih() {
  sed -u -E \
    -e 's/(Encoded authorization failure message:)[[:space:]]*[^[:space:]]+/\1 <disamarkan>/g' \
    -e 's#(assumed-role|user|role)/([A-Za-z0-9+=,.@_-]+)/[^[:space:]"]+#\1/\2/<sesi>#g' \
    -e 's/(AROA|AIDA)[A-Z0-9]{12,}:[^"[:space:],]+/\1:<sesi>/g' \
    -e 's/user[0-9]+=[^"[:space:],]+/<sesi>/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
    -e 's/(ASIA|AKIA|AIDA|AROA)[A-Z0-9]{12,}/<id-kunci>/g' \
    -e 's/[0-9]{12}/<akun>/g'
}

gagal() { echo; echo "[GAGAL] $*"; echo "        Tempel keluaran ini ke Claude; skrip aman diulang (yang sudah jadi dipakai ulang)."; exit 1; }
langkah() { echo; echo "==== $* ===="; }
guna() { [ -f "$STATE" ] && grep -E "^$1=" "$STATE" | tail -1 | cut -d= -f2-; }
simpan() { touch "$STATE"; { grep -vE "^$1=" "$STATE" 2>/dev/null; echo "$1=$2"; } > "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; }
pilih_python() { local p; for p in python3 python; do if "$p" -c 'import json' >/dev/null 2>&1; then echo "$p"; return; fi; done; }

# tes_url <url> <awalan jawaban "kode tipe"> [percobaan] [jeda detik]
tes_url() {
  local url="$1" harap="$2" n="${3:-6}" jeda="${4:-5}" hasil="" i
  for i in $(seq 1 "$n"); do
    hasil="$(curl -s -o /dev/null -w '%{http_code} %{content_type}' --max-time 25 "$url" 2>/dev/null)"
    case "$hasil" in "$harap"*) echo "[OK] $hasil  <- ${url%%\?*}"; return 0;; esac
    [ "$i" -lt "$n" ] && sleep "$jeda"
  done
  echo "[GAGAL] jawaban terakhir: ${hasil:-tidak ada}  <- ${url%%\?*}"; return 1
}

cari_kebijakan() { # cari_kebijakan <cache|origin> <nama bawaan> <id cadangan>
  local id=""
  if [ "$1" = cache ]; then
    id="$(aws cloudfront list-cache-policies --type managed --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='$2'].CachePolicy.Id | [0]" --output text 2>/dev/null)"
  else
    id="$(aws cloudfront list-origin-request-policies --type managed --query "OriginRequestPolicyList.Items[?OriginRequestPolicy.OriginRequestPolicyConfig.Name=='$2'].OriginRequestPolicy.Id | [0]" --output text 2>/dev/null)"
  fi
  if [ -z "$id" ] || [ "$id" = "None" ]; then echo "(kebijakan $2 tidak ditemukan lewat nama; memakai ID dari dokumentasi)" >&2; id="$3"; fi
  echo "$id"
}

# ------------------------------------------------------------------------------------------------ HAPUS
hapus() {
  local B F D CP CPNEW
  B="$(guna BUCKET_NAME)"; F="$(guna FUNCTION_NAME)"; D="$(guna DISTRIBUTION_ID)"; CP="$(guna CACHE_POLICY_ID)"; CPNEW="$(guna CACHE_POLICY_DIBUAT)"
  local akun_skrg akun_lama; akun_skrg="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; akun_lama="$(guna AKUN)"
  if [ -n "$akun_lama" ] && [ "$akun_lama" != "$akun_skrg" ]; then
    echo "Catatan $STATE berasal dari akun/sesi sandbox lain (sumber dayanya sudah dihapus AWS saat sesi itu habis)."
    echo "Tidak ada yang perlu dihapus; catatan dibuang."; rm -f "$STATE"; return 0
  fi
  if [ -z "$B$F$D" ]; then echo "Tidak ada catatan di $STATE: tidak ada yang dibuat skrip ini. Tidak ada yang dihapus."; return 0; fi
  echo "Yang AKAN DIHAPUS (hanya yang dibuat skrip ini, menurut $STATE):"
  [ -n "$D" ] && echo "  - distribusi CloudFront $D"
  [ -n "$CP" ] && [ "$CPNEW" = "1" ] && echo "  - kebijakan cache $CP_NAME"
  [ -n "$F" ] && echo "  - fungsi Lambda $F"
  [ -n "$B" ] && echo "  - bucket S3 $B BESERTA SELURUH ISINYA (tidak bisa dipulihkan)"
  if [ "${YA:-}" != "1" ]; then
    echo; echo "Belum ada yang dihapus. Untuk melanjutkan jalankan:  YA=1 bash deploy/lambda/siapkan-gambar.sh hapus"; return 0
  fi
  local PY; PY="$(pilih_python)"
  if [ -n "$D" ] && ! aws cloudfront get-distribution --id "$D" >/dev/null 2>&1; then
    echo "[LEWATI] distribusi $D sudah tidak ada"; D=""
  fi
  if [ -n "$D" ]; then
    langkah "CloudFront: nonaktifkan lalu hapus $D (5 sampai 15 menit)"
    local ETAG
    ETAG="$(aws cloudfront get-distribution-config --id "$D" --query ETag --output text 2>&1)" || gagal "get-distribution-config: $ETAG"
    aws cloudfront get-distribution-config --id "$D" --query DistributionConfig --output json > "$STATE.cfg.json" || gagal "tidak bisa membaca konfigurasi distribusi"
    [ -z "$PY" ] && gagal "python tidak ada; tidak bisa menonaktifkan distribusi otomatis. Nonaktifkan di console, lalu ulangi."
    "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); d['Enabled']=False; json.dump(d,open(sys.argv[2],'w'))" "$STATE.cfg.json" "$STATE.cfg-off.json" || gagal "gagal menyiapkan konfigurasi nonaktif"
    aws cloudfront update-distribution --id "$D" --if-match "$ETAG" --distribution-config "file://$STATE.cfg-off.json" >/dev/null || gagal "update-distribution (nonaktifkan) gagal"
    aws cloudfront wait distribution-deployed --id "$D" || gagal "menunggu distribusi nonaktif gagal"
    ETAG="$(aws cloudfront get-distribution --id "$D" --query ETag --output text)"
    aws cloudfront delete-distribution --id "$D" --if-match "$ETAG" || gagal "delete-distribution gagal"
    echo "[OK] distribusi dihapus"; rm -f "$STATE.cfg.json" "$STATE.cfg-off.json"
  fi
  if [ -n "$CP" ] && [ "$CPNEW" = "1" ]; then
    local ETAG2; ETAG2="$(aws cloudfront get-cache-policy --id "$CP" --query ETag --output text 2>/dev/null)"
    aws cloudfront delete-cache-policy --id "$CP" --if-match "$ETAG2" >/dev/null && echo "[OK] kebijakan cache dihapus" || echo "[LEWATI] kebijakan cache tidak terhapus (mungkin masih dipakai)"
  fi
  if [ -n "$F" ]; then aws lambda delete-function --function-name "$F" && echo "[OK] fungsi Lambda dihapus" || echo "[LEWATI] fungsi Lambda tidak terhapus"; fi
  if [ -n "$B" ]; then aws s3 rb "s3://$B" --force >/dev/null && echo "[OK] bucket dihapus" || echo "[LEWATI] bucket tidak terhapus"; fi
  rm -f "$STATE"
  echo; echo "Selesai. Catatan $STATE dihapus."
}

# ------------------------------------------------------------------------------------------------ BUAT
buat() {
  echo "================ siapkan-gambar $(date -u +%Y-%m-%dT%H:%M:%SZ) ================"
  command -v aws  >/dev/null 2>&1 || gagal "aws (AWS CLI) tidak ditemukan. Jalankan di AWS CloudShell."
  command -v curl >/dev/null 2>&1 || gagal "curl tidak ditemukan."
  REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null)}}"
  [ -z "$REGION" ] && gagal "region belum diketahui: export AWS_REGION=us-east-1"
  export AWS_REGION="$REGION"
  local akun; akun="$(aws sts get-caller-identity --query Account --output text 2>&1)"
  echo "$akun" | grep -Eq '^[0-9]{12}$' || gagal "kredensial AWS tidak sah: $akun"
  echo "region : $REGION    akun: ********${akun: -4}"
  # Sandbox AWS Academy bersifat SEMENTARA: saat timer sesi habis seluruh sumber daya dihapus, dan sesi berikutnya bisa
  # berupa akun lain. Catatan dari sesi lama tidak boleh dipakai ulang.
  local akun_lama; akun_lama="$(guna AKUN)"
  if [ -n "$akun_lama" ] && [ "$akun_lama" != "$akun" ]; then
    echo "[INFO] catatan lama berasal dari akun/sesi sandbox lain; dibuang, semuanya dibuat dari awal."
    rm -f "$STATE"
  fi
  simpan AKUN "$akun"
  [ -d "$LAMBDA_DIR" ] || gagal "folder lambda/ tidak ditemukan di $LAMBDA_DIR (jalankan dari hasil git clone)"
  [ -f "$BUAT_FUNGSI" ] || gagal "buat-fungsi.sh tidak ditemukan di $BUAT_FUNGSI (unggah deploy/lambda/buat-fungsi.sh)"
  command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 && command -v zip >/dev/null 2>&1 \
    || gagal "node, npm, atau zip tidak ada. Di CloudShell: sudo dnf install -y nodejs npm zip"

  # -------- 1. S3
  langkah "1/5 Bucket S3"
  local B; B="$(guna BUCKET_NAME)"; [ -z "$B" ] && B="${BUCKET_NAME:-puisi-gambar-$(date +%s | tail -c 7)-$RANDOM}"
  if aws s3api head-bucket --bucket "$B" >/dev/null 2>&1; then
    echo "bucket $B sudah ada, dipakai ulang"
  else
    if [ "$REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$B" >/dev/null 2>"$STATE.err" || gagal "create-bucket $B: $(head -c 300 "$STATE.err")"
    else
      aws s3api create-bucket --bucket "$B" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null 2>"$STATE.err" || gagal "create-bucket $B: $(head -c 300 "$STATE.err")"
    fi
    echo "bucket $B dibuat"
  fi
  simpan BUCKET_NAME "$B"
  aws s3api put-public-access-block --bucket "$B" --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false 2>"$STATE.err" \
    || gagal "put-public-access-block: $(head -c 300 "$STATE.err")  (akun/sandbox mungkin melarang akses publik S3)"
  local POL; POL="$(mktemp)"
  cat > "$POL" <<EOF
{"Version":"2012-10-17","Statement":[{"Sid":"PublicReadGetObject","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::$B/*"}]}
EOF
  local i ok=0
  for i in 1 2 3 4; do
    if aws s3api put-bucket-policy --bucket "$B" --policy "file://$POL" 2>"$STATE.err"; then ok=1; break; fi
    sleep 4
  done
  [ "$ok" = 1 ] || gagal "put-bucket-policy: $(head -c 300 "$STATE.err")"
  aws s3api put-bucket-website --bucket "$B" --website-configuration '{"IndexDocument":{"Suffix":"index.html"}}' 2>"$STATE.err" \
    || gagal "put-bucket-website: $(head -c 300 "$STATE.err")"
  echo "[OK] akses publik, bucket policy baca-publik, dan static website hosting terpasang"

  # -------- 2. Lambda
  langkah "2/5 Fungsi Lambda ($FUNCTION_NAME)"
  BUCKET_NAME="$B" FUNCTION_NAME="$FUNCTION_NAME" AWS_REGION="$REGION" bash "$BUAT_FUNGSI" || gagal "buat-fungsi.sh gagal (lihat pesan di atas dan deploy/lambda/README.md bagian Bila gagal)"
  simpan FUNCTION_NAME "$FUNCTION_NAME"
  local FURL; FURL="$(aws lambda get-function-url-config --function-name "$FUNCTION_NAME" --query FunctionUrl --output text 2>"$STATE.err")" \
    || gagal "get-function-url-config: $(head -c 300 "$STATE.err")"
  simpan FUNCTION_URL "$FURL"

  # -------- 3. Latar
  langkah "3/5 Berkas latar di S3"
  local NAMA_LATAR
  NAMA_LATAR="$(grep -oE 'latar[0-9]+\.jpeg' "$API_JS" 2>/dev/null | sort -u | tr '\n' ' ')"
  [ -z "$NAMA_LATAR" ] && NAMA_LATAR="latar1.jpeg latar2.jpeg latar3.jpeg latar5.jpeg"
  echo "nama berkas yang dipakai web/js/api.js: $NAMA_LATAR"
  local ada_semua=1 f
  for f in $NAMA_LATAR; do [ -f "$LATAR_DIR/$f" ] || ada_semua=0; done
  local PLACEHOLDER=0
  if [ "$ada_semua" = 0 ]; then
    echo "[PERHATIAN] berkas latar dari dosen tidak lengkap di $LATAR_DIR."
    echo "            Dibuatkan PENGGANTI SEMENTARA (warna polos) supaya seluruh alur bisa diuji."
    echo "            Ganti nanti dengan berkas dosen: letakkan di $LATAR_DIR lalu jalankan skrip ini lagi."
    mkdir -p "$LATAR_DIR"
    LATAR_DIR="$(cd "$LATAR_DIR" && pwd)"      # jalur absolut: pembuat latar dijalankan dari folder lambda/
    local GEN="$LAMBDA_DIR/.buat-latar-pengganti.mjs"
    cat > "$GEN" <<EOF
import Jimp from "jimp";
const dir = process.argv[2];
const warna = [0xf5deb3ff, 0xb0c4deff, 0xc8e6c9ff, 0xe6c75aff, 0xd7bde2ff, 0xf5b7b1ff];
let i = 0;
for (const nama of process.argv.slice(3)) {
  const j = new Jimp(1280, 720, warna[i++ % warna.length]);
  await j.writeAsync(dir + "/" + nama);
}
EOF
    # hanya berkas yang KURANG yang dibuatkan pengganti; milik dosen yang sudah ada tidak ditimpa.
    # jimp berada di lambda/node_modules (dipasang oleh buat-fungsi.sh pada langkah 2).
    local kurang=""
    for f in $NAMA_LATAR; do [ -f "$LATAR_DIR/$f" ] || kurang="$kurang $f"; done
    ( cd "$LAMBDA_DIR" && node "$GEN" "$LATAR_DIR" $kurang ) \
      || { rm -f "$GEN"; gagal "gagal membuat latar pengganti (jimp tidak terpasang?)"; }
    rm -f "$GEN"
    PLACEHOLDER=1
  fi
  for f in $NAMA_LATAR; do
    aws s3 cp "$LATAR_DIR/$f" "s3://$B/$f" --content-type image/jpeg >/dev/null 2>"$STATE.err" || gagal "unggah $f: $(head -c 300 "$STATE.err")"
    echo "[OK] diunggah: $f"
  done
  simpan LATAR_PENGGANTI "$PLACEHOLDER"
  local PRIMER; PRIMER="$(echo "$NAMA_LATAR" | awk '{print $1}')"
  local DID; DID="$(guna DISTRIBUTION_ID)"
  if [ -n "$DID" ]; then
    aws cloudfront create-invalidation --distribution-id "$DID" --paths '/latar*' >/dev/null 2>&1 && echo "[OK] cache CloudFront untuk /latar* dibersihkan" || echo "[LEWATI] invalidation gagal (tidak fatal)"
  fi

  # -------- 4. Uji Lambda langsung
  langkah "4/5 Uji fungsi Lambda langsung"
  local LU="${FURL%/}/fungsi?action=preview&template=$PRIMER&judul=Uji&penulis=Skrip&kutipan=halo"
  tes_url "$LU" "200 image/jpeg" 8 5 || gagal "Lambda tidak menjawab gambar. 403 = izin Function URL; 500 = berkas latar/izin S3 LabRole (lihat deploy/lambda/README.md)"

  # -------- 5. CloudFront
  langkah "5/5 CloudFront"
  local S3HOST="" cand
  for cand in "$B.s3-website-$REGION.amazonaws.com" "$B.s3-website.$REGION.amazonaws.com"; do
    if tes_url "http://$cand/$PRIMER" "200" 6 4 >/dev/null; then S3HOST="$cand"; break; fi
  done
  [ -n "$S3HOST" ] || gagal "endpoint website S3 tidak menjawab 200 untuk $PRIMER"
  echo "origin S3 website : $S3HOST"
  local LHOST="${FURL#https://}"; LHOST="${LHOST%/}"
  echo "origin Lambda URL : $LHOST"

  local CP_OPT ORP CP_QS
  CP_OPT="$(cari_kebijakan cache Managed-CachingOptimized "$ID_CP_CACHING_OPTIMIZED")"
  ORP="$(cari_kebijakan origin Managed-AllViewerExceptHostHeader "$ID_ORP_ALLVIEWER_TANPA_HOST")"
  CP_QS="$(guna CACHE_POLICY_ID)"
  if [ -n "$CP_QS" ] && ! aws cloudfront get-cache-policy --id "$CP_QS" >/dev/null 2>&1; then
    echo "kebijakan cache dari catatan ($CP_QS) sudah tidak ada; dibuat ulang"
    CP_QS=""; simpan CACHE_POLICY_ID ""; simpan CACHE_POLICY_DIBUAT 0
  fi
  if [ -z "$CP_QS" ]; then
    CP_QS="$(aws cloudfront list-cache-policies --type custom --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='$CP_NAME'].CachePolicy.Id | [0]" --output text 2>/dev/null)"
    if [ -n "$CP_QS" ] && [ "$CP_QS" != "None" ]; then
      echo "kebijakan cache $CP_NAME sudah ada, dipakai ulang"
    else
      local CPJ; CPJ="$(mktemp)"
      cat > "$CPJ" <<EOF
{"Name":"$CP_NAME","Comment":"query string masuk kunci cache; tanpa header/cookie; TTL mengikuti Cache-Control dari Lambda","DefaultTTL":0,"MaxTTL":86400,"MinTTL":0,
 "ParametersInCacheKeyAndForwardedToOrigin":{"EnableAcceptEncodingGzip":false,"EnableAcceptEncodingBrotli":false,
  "HeadersConfig":{"HeaderBehavior":"none"},"CookiesConfig":{"CookieBehavior":"none"},"QueryStringsConfig":{"QueryStringBehavior":"all"}}}
EOF
      CP_QS="$(aws cloudfront create-cache-policy --cache-policy-config "file://$CPJ" --query CachePolicy.Id --output text 2>"$STATE.err")" \
        || gagal "create-cache-policy: $(head -c 300 "$STATE.err")"
      simpan CACHE_POLICY_DIBUAT 1
      echo "kebijakan cache $CP_NAME dibuat"
    fi
    simpan CACHE_POLICY_ID "$CP_QS"
  fi
  echo "kebijakan: cache-S3=$CP_OPT  cache-fungsi=$CP_QS  origin-request=$ORP"

  local DOMAIN=""
  DID="$(guna DISTRIBUTION_ID)"
  if [ -n "$DID" ] && DOMAIN="$(aws cloudfront get-distribution --id "$DID" --query Distribution.DomainName --output text 2>/dev/null)" && [ -n "$DOMAIN" ] && [ "$DOMAIN" != "None" ]; then
    echo "distribusi $DID sudah ada ($DOMAIN), dipakai ulang"
  else
    local CFJ; CFJ="$(mktemp)"
    cat > "$CFJ" <<EOF
{
  "CallerReference": "puisi-gambar-$(date +%s)",
  "Comment": "puisi gambar kutipan (dibuat siapkan-gambar.sh)",
  "Enabled": true,
  "PriceClass": "PriceClass_100",
  "HttpVersion": "http2",
  "IsIPV6Enabled": true,
  "Origins": {"Quantity": 2, "Items": [
    {"Id": "s3-website", "DomainName": "$S3HOST",
     "CustomOriginConfig": {"HTTPPort": 80, "HTTPSPort": 443, "OriginProtocolPolicy": "http-only",
       "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}}},
    {"Id": "lambda-url", "DomainName": "$LHOST",
     "CustomOriginConfig": {"HTTPPort": 80, "HTTPSPort": 443, "OriginProtocolPolicy": "https-only",
       "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}}}
  ]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-website",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"], "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}},
    "Compress": true,
    "CachePolicyId": "$CP_OPT"
  },
  "CacheBehaviors": {"Quantity": 1, "Items": [
    {"PathPattern": "/fungsi*",
     "TargetOriginId": "lambda-url",
     "ViewerProtocolPolicy": "redirect-to-https",
     "AllowedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"], "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}},
     "Compress": false,
     "CachePolicyId": "$CP_QS",
     "OriginRequestPolicyId": "$ORP"}
  ]}
}
EOF
    local HASIL
    HASIL="$(aws cloudfront create-distribution --distribution-config "file://$CFJ" --query '[Distribution.Id,Distribution.DomainName]' --output text 2>"$STATE.err")" \
      || gagal "create-distribution: $(head -c 400 "$STATE.err")  (CloudFront mungkin tidak diizinkan di sandbox)"
    DID="$(echo "$HASIL" | awk '{print $1}')"; DOMAIN="$(echo "$HASIL" | awk '{print $2}')"
    simpan DISTRIBUTION_ID "$DID"
    echo "distribusi $DID dibuat ($DOMAIN)"
  fi
  simpan CDN_URL "https://$DOMAIN"
  echo "menunggu CloudFront selesai (biasanya 3 sampai 15 menit; jangan ditutup)..."
  aws cloudfront wait distribution-deployed --id "$DID" 2>"$STATE.err" || echo "[PERHATIAN] 'wait' berhenti: $(head -c 200 "$STATE.err"); lanjut menguji."

  langkah "Uji lewat CloudFront"
  local CDN="https://$DOMAIN" lulus=0
  tes_url "$CDN/fungsi?action=preview&template=$PRIMER&judul=Uji&penulis=Skrip&kutipan=halo" "200 image/jpeg" 10 10 && lulus=$((lulus+1))
  tes_url "$CDN/$PRIMER" "200 image/jpeg" 10 10 && lulus=$((lulus+1))

  echo
  echo "================ RINGKASAN ================"
  echo "bucket     : $B"
  echo "fungsi     : $FUNCTION_NAME"
  echo "distribusi : $DID"
  echo "uji CloudFront lulus: $lulus dari 2"
  echo
  echo "CDN_URL=$CDN"
  echo
  echo "Dipakai di Fase 2 (sebelum membangun image gateway):   export CDN_URL=$CDN"
  [ "$PLACEHOLDER" = 1 ] && echo "INGAT: latar saat ini PENGGANTI polos. Ganti dengan berkas dosen: taruh di $LATAR_DIR lalu jalankan ulang skrip ini."
  [ "$lulus" = 2 ] || echo "Ada uji yang belum lulus: tempel keluaran ini ke Claude."
}

set -o pipefail   # kode keluar = kode buat/hapus, bukan kode penyaring
case "$MODE" in
  buat)  buat  2>&1 | bersih ;;
  hapus) hapus 2>&1 | bersih ;;
  *) echo "Pemakaian: bash siapkan-gambar.sh [buat|hapus]" ;;
esac
