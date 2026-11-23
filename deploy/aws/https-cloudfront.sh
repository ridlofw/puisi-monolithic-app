#!/usr/bin/env bash
# deploy/aws/https-cloudfront.sh : HTTPS untuk SELURUH aplikasi lewat CloudFront di depan ALB (CloudFront -> ALB -> gateway).
#
# Kenapa CloudFront: di sandbox ini ALB tidak bisa ber-HTTPS (butuh sertifikat ACM dan domain; ACM dan Route 53 tidak ada di daftar
# layanan yang diizinkan). CloudFront memberi HTTPS gratis lewat sertifikat bawaan *.cloudfront.net.
#
#   bash https-cloudfront.sh buat     # distribusi baru: asal = ALB (HTTP), HTTPS ke pengunjung; menunggu selesai; menguji
#   bash https-cloudfront.sh status
#   YA=1 bash https-cloudfront.sh hapus
# Prasyarat: alb.sh buat sudah dijalankan (~/puisi9/alb-dns ada).
#
# CATATAN PENTING (diketahui, belum diperbaiki):
#  - Cache DIMATIKAN (kebijakan CachingDisabled) dan semua header diteruskan (AllViewer): aplikasi dinamis (login, kirim puisi) tidak boleh di-cache.
#  - Gateway membatasi login per IP (limit_req) dan membaca IP klien dari X-Forwarded-For hanya dari jaringan privat. Di belakang CloudFront, IP yang
#    terbaca adalah IP edge CloudFront, bukan IP pengunjung: batas 10 login/menit dihitung per edge, bukan per orang. Untuk demo tak masalah;
#    perbaikan: tambahkan rentang IP CloudFront ke set_real_ip_from di deploy/swarm/gateway/00-swarm.conf.
#  - ALB masih bisa dijangkau langsung lewat HTTP. Untuk menutupnya, batasi Security Group ALB ke prefix list com.amazonaws.global.cloudfront.origin-facing.
#
# STATUS: JSON konfigurasi divalidasi offline terhadap model API (botocore) lewat JSON_SAJA=1; pembuatan di AWS diuji saat dijalankan.
export AWS_PAGER=""
W="$HOME/puisi9"
MODE="${1:-buat}"
ID_CP_CACHING_DISABLED="4135ea2d-6df8-44a3-9df3-4b5a84be39ad"       # Managed-CachingDisabled
ID_ORP_ALLVIEWER="216adef6-5c7f-47e4-b989-5492eafa07d3"              # Managed-AllViewer

bersih() {
  sed -u -E \
    -e 's#(assumed-role|user|role)/([A-Za-z0-9+=,.@_-]+)/[^[:space:]"]+#\1/\2/<sesi>#g' \
    -e 's/user[0-9]+=[^"[:space:],]+/<sesi>/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
    -e 's/[0-9]{12}/<akun>/g'
}
gagal() { echo "[GAGAL] $*"; exit 1; }
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

tulis_json() { # tulis_json <berkas> <dns-alb> <id-cache> <id-origin-request>
  cat > "$1" <<EOF
{
  "CallerReference": "puisi-app-$(date +%s)",
  "Comment": "puisi aplikasi HTTPS di depan ALB (dibuat https-cloudfront.sh)",
  "Enabled": true,
  "PriceClass": "PriceClass_100",
  "HttpVersion": "http2",
  "IsIPV6Enabled": true,
  "Origins": {"Quantity": 1, "Items": [
    {"Id": "alb", "DomainName": "$2",
     "CustomOriginConfig": {"HTTPPort": 80, "HTTPSPort": 443, "OriginProtocolPolicy": "http-only",
       "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}, "OriginReadTimeout": 30, "OriginKeepaliveTimeout": 5}}
  ]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "alb",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {"Quantity": 7, "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
                       "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}},
    "Compress": true,
    "CachePolicyId": "$3",
    "OriginRequestPolicyId": "$4"
  }
}
EOF
}

uji_url() { # uji_url <url> <kode-harapan> [argumen curl tambahan...]
  local url="$1" harap="$2" k i; shift 2
  for i in 1 2 3 4 5 6; do
    k="$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$@" "$url" 2>/dev/null)"
    [ "$k" = "$harap" ] && { echo "[OK] $k  <- $url"; return 0; }
    sleep 8
  done
  echo "[GAGAL] jawaban terakhir $k (harapan $harap)  <- $url"; return 1
}

buat() {
  if [ "${JSON_SAJA:-}" = "1" ]; then   # mode uji offline: hanya menulis JSON, tidak memanggil AWS
    tulis_json "${JSON_KELUAR:-/tmp/dist-app.json}" "contoh-alb.us-east-1.elb.amazonaws.com" "$ID_CP_CACHING_DISABLED" "$ID_ORP_ALLVIEWER"
    echo "JSON ditulis ke ${JSON_KELUAR:-/tmp/dist-app.json}"; return 0
  fi
  command -v aws >/dev/null 2>&1 || gagal "aws tidak ditemukan; jalankan di AWS CloudShell"
  local ALB CP ORP ID DOM CFJ
  ALB="$(cat "$W/alb-dns" 2>/dev/null)"; [ -n "$ALB" ] || gagal "belum ada ~/puisi9/alb-dns (jalankan alb.sh buat)"
  CP="$(cari_kebijakan cache Managed-CachingDisabled "$ID_CP_CACHING_DISABLED")"
  ORP="$(cari_kebijakan origin Managed-AllViewer "$ID_ORP_ALLVIEWER")"
  echo "kebijakan: cache=$CP origin-request=$ORP"
  ID="$(cat "$W/cf-app-id" 2>/dev/null)"
  if [ -n "$ID" ] && DOM="$(aws cloudfront get-distribution --id "$ID" --query Distribution.DomainName --output text 2>/dev/null)" && [ -n "$DOM" ] && [ "$DOM" != None ]; then
    echo "distribusi $ID sudah ada ($DOM), dipakai ulang"
  else
    CFJ="$(mktemp)"; tulis_json "$CFJ" "$ALB" "$CP" "$ORP"
    local H; H="$(aws cloudfront create-distribution --distribution-config "file://$CFJ" --query '[Distribution.Id,Distribution.DomainName]' --output text 2>"$W/err.txt")" \
      || gagal "create-distribution: $(head -c 400 "$W/err.txt")"
    ID="$(echo "$H" | awk '{print $1}')"; DOM="$(echo "$H" | awk '{print $2}')"
    echo "$ID" > "$W/cf-app-id"; echo "distribusi $ID dibuat ($DOM)"
  fi
  echo "$DOM" > "$W/cf-app-dns"
  echo "menunggu CloudFront selesai (3 sampai 15 menit; jangan ditutup)..."
  aws cloudfront wait distribution-deployed --id "$ID" 2>"$W/err.txt" || echo "[PERHATIAN] 'wait' berhenti: $(head -c 200 "$W/err.txt"); lanjut menguji."
  echo; echo "==== Uji lewat HTTPS ===="
  local lulus=0
  uji_url "https://$DOM/" 200 && lulus=$((lulus+1))
  uji_url "https://$DOM/api/puisi/sehat" 200 && lulus=$((lulus+1))
  uji_url "http://$DOM/" 301 && lulus=$((lulus+1))                                  # HTTP harus dialihkan ke HTTPS
  uji_url "https://$DOM/api/auth/login" 401 -X POST -H 'Content-Type: application/json' -d '{"username":"tidak-ada","password":"salah"}' && lulus=$((lulus+1))   # POST harus lolos sampai ke aplikasi
  echo; echo "uji lulus: $lulus dari 4"
  echo "ALAMAT APLIKASI (HTTPS): https://$DOM/"
}

status() {
  local ID; ID="$(cat "$W/cf-app-id" 2>/dev/null)"; [ -n "$ID" ] || gagal "belum ada distribusi aplikasi"
  aws cloudfront get-distribution --id "$ID" --query '[Distribution.Status,Distribution.DomainName,DistributionConfig.Enabled]' --output text
}

hapus() {
  [ "${YA:-}" = "1" ] || { echo "Ini menghapus distribusi CloudFront aplikasi. Jalankan: YA=1 bash https-cloudfront.sh hapus"; return 0; }
  local ID PY ETAG; ID="$(cat "$W/cf-app-id" 2>/dev/null)"; [ -n "$ID" ] || { echo "tidak ada yang dihapus"; return 0; }
  PY="$(pilih_python)"; [ -n "$PY" ] || gagal "python tidak ada"
  ETAG="$(aws cloudfront get-distribution-config --id "$ID" --query ETag --output text)" || gagal "get-distribution-config"
  aws cloudfront get-distribution-config --id "$ID" --query DistributionConfig --output json > "$W/cfa.json"
  "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); d['Enabled']=False; json.dump(d,open(sys.argv[2],'w'))" "$W/cfa.json" "$W/cfa-off.json"
  aws cloudfront update-distribution --id "$ID" --if-match "$ETAG" --distribution-config "file://$W/cfa-off.json" >/dev/null || gagal "update-distribution"
  aws cloudfront wait distribution-deployed --id "$ID"
  ETAG="$(aws cloudfront get-distribution --id "$ID" --query ETag --output text)"
  aws cloudfront delete-distribution --id "$ID" --if-match "$ETAG" && echo "distribusi dihapus" && rm -f "$W/cf-app-id" "$W/cf-app-dns"
}

set -o pipefail
case "$MODE" in
  buat) buat 2>&1 | bersih ;;
  status) status 2>&1 | bersih ;;
  hapus) hapus 2>&1 | bersih ;;
  *) echo "Pemakaian: bash https-cloudfront.sh [buat|status|hapus]" ;;
esac
