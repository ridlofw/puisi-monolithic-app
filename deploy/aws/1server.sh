#!/usr/bin/env bash
# deploy/aws/1server.sh : versi SINGLE (non-scalable). SATU server t3.small menjalankan seluruh aplikasi dengan Docker Compose
# (deploy/aws/1server/compose.yaml: setiap komponen hanya satu, tanpa replika dan klaster). Dijalankan dari AWS CloudShell.
# Server diatur lewat SSM (tanpa kunci SSH). Panduan langkah demi langkah: docs/PANDUAN-DEPLOY-AWS-1-SERVER.md.
#
#   bash 1server.sh luncurkan     # Security Group puisi-1server-sg (tanpa port terbuka) + 1 t3.small Amazon Linux 2023
#                                 # (30 GiB, swap 4 GiB, Docker + Compose + buildx dipasang lewat user-data)
#   bash 1server.sh tunggu        # tunggu server terdaftar di SSM dan Docker, Compose, buildx siap
#   bash 1server.sh kode          # server mengambil kode langsung dari GitHub (git clone cabang yang sama dengan ~/puisi1/kode), buat rahasia
#   bash 1server.sh bangun        # bangun semua image di server (latar belakang)
#   bash 1server.sh status        # log pembangunan image
#   bash 1server.sh naik          # docker compose up -d (semua layanan)
#   bash 1server.sh verifikasi    # container, gateway, memori, lalu scripts/uji_e2e.py dari dalam server
#   bash 1server.sh memori        # free -m, swap, beban, dan memori per container
#   bash 1server.sh buka          # izinkan port 80 HANYA dari CloudFront (prefix list milik AWS), lalu tulis alamat publik server
#   bash 1server.sh cloudfront    # distribusi dua jalur (halaman dari S3, /fungsi ke Lambda, /api dan /audio ke server ini)
#   bash 1server.sh jalankan 'docker ps'   # perintah apa pun di server
#   YA=1 bash 1server.sh hapus    # hapus server dan Security Group yang dibuat skrip ini
#                                 # (Lambda, bucket S3, dan CloudFront dihapus dengan skripnya sendiri, lihat panduan)
#
# Persiapan di CloudShell (sekali): git clone -b <cabang> https://github.com/ridlofw/puisi-monolithic-app.git ~/puisi1/kode
# Semua catatan keadaan ada di ~/puisi1 (TIDAK memakai ~/puisi9 milik versi 9 server). Aman diulang.
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off
REGION="${AWS_REGION:-us-east-1}"; export AWS_REGION="$REGION"
TIPE="${TIPE:-t3.small}"
NAMA="${NAMA:-puisi-single}"
SG_NAMA="puisi-1server-sg"
W="$HOME/puisi1"; mkdir -p "$W"
KODE_DIR="$W/kode"                       # salinan repositori di CloudShell (git clone; dipakai siapkan-gambar.sh dan cloudfront-dua-jalur.sh)
REPO="${REPO:-https://github.com/ridlofw/puisi-monolithic-app.git}"
STATE_GAMBAR="$W/gambar.state"           # catatan deploy/lambda/siapkan-gambar.sh untuk versi Single
DC="docker compose -f deploy/aws/1server/compose.yaml --project-directory ."
COMPOSE_VER="v2.29.7"
BUILDX_VER="v0.17.1"

bersih() {
  sed -u -E \
    -e 's/(Encoded authorization failure message:)[[:space:]]*[^[:space:]]+/\1 <disamarkan>/g' \
    -e 's#:(assumed-role|user|role)/([A-Za-z0-9+=,.@_-]+)/[^[:space:]"]+#:\1/\2/<sesi>#g' \
    -e 's/(AROA|AIDA)[A-Z0-9]{12,}:[^"[:space:],]+/\1:<sesi>/g' \
    -e 's/user[0-9]+=[^"[:space:],]+/<sesi>/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
    -e 's/(ASIA|AKIA|AIDA|AROA)[A-Z0-9]{12,}/<id-kunci>/g' \
    -e 's/[0-9]{12}/<akun>/g'
}
gagal() { echo "[GAGAL] $*"; exit 1; }
id_server() { cat "$W/instance-id" 2>/dev/null; }

# ssm <perintah>: jalankan di server, cetak stdout (stderr dengan awalan), kode keluar 0 bila Success. Sama dengan 9server.sh.
ssm() {
  local id; id="$(id_server)"; [ -n "$id" ] || { echo "[GAGAL] belum ada $W/instance-id (jalankan luncurkan)"; return 1; }
  local pj; pj="$(mktemp)"
  python3 -c 'import json,sys; print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":["1700"]}))' "$*" > "$pj"
  local cid st="" i err
  cid="$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript --parameters "file://$pj" --query Command.CommandId --output text 2>&1)" \
    || { echo "[GAGAL kirim ssm] $cid"; rm -f "$pj"; return 1; }
  rm -f "$pj"
  for i in $(seq 1 "${SSM_TUNGGU:-80}"); do
    st="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null)"
    case "$st" in Success|Failed|Cancelled|TimedOut) break;; esac
    sleep 3
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardOutputContent --output text 2>/dev/null
  err="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query StandardErrorContent --output text 2>/dev/null | head -8)"
  [ -n "$err" ] && [ "$err" != "None" ] && echo "[stderr] $err"
  [ "$st" = "Success" ] || { echo "[status ssm: ${st:-tak-diketahui}]"; return 1; }
}

luncurkan() {
  echo "==== 1. Jaringan, Security Group, AMI ===="
  local VPC SG AMI SUB ID
  VPC="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
  [ -n "$VPC" ] && [ "$VPC" != None ] || gagal "VPC bawaan tidak ditemukan"
  SG="$(aws ec2 describe-security-groups --filters Name=group-name,Values=$SG_NAMA Name=vpc-id,Values="$VPC" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  if [ -z "$SG" ] || [ "$SG" = None ]; then
    SG="$(aws ec2 create-security-group --group-name $SG_NAMA --description "puisi single 1 server" --vpc-id "$VPC" --query GroupId --output text)" || gagal "create-security-group"
    echo "Security Group $SG_NAMA dibuat (belum ada port masuk yang dibuka; server dikendalikan lewat SSM)"
  else
    echo "Security Group $SG_NAMA sudah ada"
  fi
  echo "$SG" > "$W/sg"
  AMI="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)"
  echo "AMI Amazon Linux 2023: $AMI   tipe: $TIPE"

  cat > "$W/user-data.sh" <<EOF
#!/bin/bash
exec > /var/log/puisi-user-data.log 2>&1
set -x
dnf install -y docker git
systemctl enable --now docker
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL --retry 5 -o /usr/local/lib/docker/cli-plugins/docker-compose https://github.com/docker/compose/releases/download/$COMPOSE_VER/docker-compose-linux-x86_64
curl -fsSL --retry 5 -o /usr/local/lib/docker/cli-plugins/docker-buildx https://github.com/docker/buildx/releases/download/$BUILDX_VER/buildx-$BUILDX_VER.linux-amd64
chmod 755 /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-buildx
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab
sysctl -w vm.max_map_count=262144 && echo vm.max_map_count=262144 > /etc/sysctl.d/99-puisi.conf
mkdir -p /opt/puisi
touch /var/log/puisi-siap
EOF

  echo "==== 2. Meluncurkan 1 server ===="
  ID="$(aws ec2 describe-instances --filters Name=tag:Name,Values="$NAMA" Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)"
  if [ -n "$ID" ] && [ "$ID" != None ]; then
    echo "$NAMA sudah ada ($ID)"
  else
    SUB="$(aws ec2 describe-subnets --filters Name=availability-zone,Values="${REGION}a" Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)"
    ID="$(aws ec2 run-instances --image-id "$AMI" --instance-type "$TIPE" --count 1 --subnet-id "$SUB" --security-group-ids "$SG" \
      --iam-instance-profile Name=LabInstanceProfile --key-name vockey \
      --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3}' \
      --user-data "file://$W/user-data.sh" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAMA}]" \
      --query 'Instances[0].InstanceId' --output text 2>"$W/err.txt")" \
      || gagal "meluncurkan $NAMA: $(head -c 400 "$W/err.txt")"
    echo "$NAMA dibuat di zona ${REGION}a ($ID)"
  fi
  echo "$ID" > "$W/instance-id"
  aws ec2 wait instance-running --instance-ids "$ID" || gagal "server tidak Running"
  aws ec2 describe-instances --instance-ids "$ID" \
    --query 'Reservations[0].Instances[0].[Tags[?Key==`Name`]|[0].Value,InstanceType,Placement.AvailabilityZone,State.Name,PublicDnsName]' --output text
  aws ec2 describe-instance-credit-specifications --instance-ids "$ID" --query 'InstanceCreditSpecifications[0].CpuCredits' --output text | sed 's/^/kredit CPU: /'
  echo "Selesai. Langkah berikut: bash 1server.sh tunggu   (2 sampai 4 menit sampai SSM dan Docker siap)"
}

tunggu() {
  echo "==== Menunggu server terdaftar di SSM (maks 10 menit) ===="
  local i st=""
  for i in $(seq 1 60); do
    st="$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$(id_server)" --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)"
    [ "$st" = Online ] && break; sleep 10
  done
  echo "SSM: ${st:-belum terdaftar}"
  [ "$st" = Online ] || gagal "SSM belum melihat server. Tunggu sebentar lalu ulangi."
  echo "==== Menunggu user-data selesai (Docker, Compose, buildx, swap) ===="
  SSM_TUNGGU=200 ssm "cloud-init status --wait >/dev/null 2>&1; test -f /var/log/puisi-siap && docker --version && docker compose version && docker buildx version && git --version && free -m | awk 'NR==2{print \"RAM total \" \$2 \" MB\"} NR==3{print \"swap \" \$2 \" MB\"}' && sysctl -n vm.max_map_count" \
    || gagal "server belum siap; lihat: bash 1server.sh jalankan 'tail -30 /var/log/puisi-user-data.log'"
}

# kode: server mengambil kode LANGSUNG dari GitHub (git clone --depth 1), cabang dan commit yang sama dengan salinan di CloudShell
# ($KODE_DIR), lalu membuat rahasia baru di server. Tidak ada bucket S3 perantara. Bila /opt/puisi sudah berisi repositori, kode diperbarui
# ke ujung cabang (aman diulang; rahasia yang sudah ada tidak diubah).
# Rahasia diberi izin 644: Compose (bukan Swarm) memasang berkas rahasia apa adanya, dan SeaweedFS di dalam container berjalan sebagai
# pengguna biasa, sehingga berkas 600 milik root membuatnya gagal start ("permission denied", terbukti di AWS 28 Nov 2026).
# Server ini hanya dipakai aplikasi ini dan tidak punya pengguna lain; folder secrets/ sendiri tetap 700.
kode() {
  [ -d "$KODE_DIR/.git" ] || gagal "$KODE_DIR belum ada. Jalankan dulu: git clone -b <cabang> $REPO $KODE_DIR"
  local CABANG; CABANG="${CABANG:-$(git -C "$KODE_DIR" rev-parse --abbrev-ref HEAD)}"
  echo "cabang: $CABANG   commit di CloudShell: $(git -C "$KODE_DIR" log -1 --format='%h %s')"
  ssm "set -e; if [ -d /opt/puisi/.git ]; then cd /opt/puisi && git fetch -q --depth 1 origin $CABANG && git checkout -q -B $CABANG FETCH_HEAD; else git clone -q --depth 1 -b $CABANG $REPO /opt/puisi.baru && cp -a /opt/puisi.baru/. /opt/puisi/ && rm -rf /opt/puisi.baru; fi; cd /opt/puisi && echo \"commit di server: \$(git log -1 --format='%h %s')\" && python3 scripts/siapkan_rahasia.py && python3 scripts/siapkan_rahasia_auth.py && python3 scripts/siapkan_rahasia_tts.py && chmod 644 secrets/* && ls deploy/aws/1server" \
    || gagal "mengambil kode dari GitHub di server"
}

# Membangun semua image di server, di latar belakang (SSM punya batas waktu). Image gateway disisipi 01-cloudfront.conf (rentang IP
# CloudFront, supaya batas login dihitung per pengunjung, bukan per edge CloudFront). CDN_URL tidak perlu: pengunjung memuat halaman dari S3
# lewat distribusi dua jalur (yang menyisipkan alamatnya sendiri ke api.js); halaman di gateway tidak dijangkau pengunjung.
bangun() {
  local CDN="${CDN_URL:-}"
  ssm "cd /opt/puisi && : > build.log && (setsid nohup bash -c 'date; bash deploy/swarm/gateway/buat-cloudfront-conf.sh && CDN_URL=$CDN $DC build --progress plain > build-lengkap.log 2>&1; echo \"KELUAR=\$? (0 berarti semua image berhasil)\"; date; echo SELESAI' > build.log 2>&1 < /dev/null &) ; sleep 1; echo mulai"
  echo "Pantau dengan: bash 1server.sh status   (sekitar 10 sampai 20 menit; tunggu baris SELESAI)"
}

status() {
  ssm "cat /opt/puisi/build.log; echo '--- akhir build-lengkap.log:'; tail -${BARIS:-8} /opt/puisi/build-lengkap.log 2>/dev/null; echo; docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep single"
}

naik() {
  SSM_TUNGGU=200 ssm "cd /opt/puisi && $DC up -d --no-build 2>&1 | tail -25 && $DC ps --format 'table {{.Service}}\t{{.Status}}'"
}

memori() {
  ssm "free -m | awk 'NR==2{printf \"RAM: terpakai %s, tersedia %s dari %s MB\n\", \$3, \$7, \$2} NR==3{printf \"swap: terpakai %s dari %s MB\n\", \$3, \$2}'; uptime | sed 's/.*load average/beban/'; vmstat 1 3 | tail -2 | awk '{print \"vmstat si=\" \$7 \" so=\" \$8 \" (KB/s masuk/keluar swap)\"}'; docker stats --no-stream --format '{{.Name}} {{.MemUsage}} CPU {{.CPUPerc}}' | sort"
}

verifikasi() {
  echo "==== container (harus semua Up; tts-audio-init Exited 0 itu normal) ===="
  ssm "cd /opt/puisi && $DC ps -a --format 'table {{.Service}}\t{{.Status}}'"
  echo "==== gateway dan layanan ===="
  ssm "curl -s -o /dev/null -w 'healthz=%{http_code}\n' http://127.0.0.1/healthz; curl -s http://127.0.0.1/api/puisi/sehat; echo; curl -s -o /dev/null -w 'galeri=%{http_code}\n' http://127.0.0.1/api/puisi"
  echo "==== memori ===="
  memori
  echo "==== uji_e2e.py dari dalam server (target 10 dari 10) ===="
  SSM_TUNGGU=120 ssm "cd /opt/puisi && GATEWAY=http://127.0.0.1 python3 scripts/uji_e2e.py --tunggu 240 2>&1 | tail -12"
}

# Port 80 dibuka HANYA untuk CloudFront (managed prefix list com.amazonaws.global.cloudfront.origin-facing), bukan untuk seluruh internet.
buka() {
  local SG PL DNS; SG="$(cat "$W/sg")"; [ -n "$SG" ] || gagal "belum ada $W/sg"
  PL="$(aws ec2 describe-managed-prefix-lists --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing --query 'PrefixLists[0].PrefixListId' --output text)"
  [ -n "$PL" ] && [ "$PL" != None ] || gagal "prefix list CloudFront tidak ditemukan"
  if aws ec2 describe-security-groups --group-ids "$SG" --query "SecurityGroups[0].IpPermissions[?FromPort==\`80\`].PrefixListIds[].PrefixListId" --output text | grep -q "$PL"; then
    echo "port 80 dari CloudFront ($PL) sudah diizinkan"
  else
    aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId=$PL,Description=CloudFront}]" >/dev/null 2>"$W/err.txt" \
      || gagal "membuka port 80 untuk CloudFront: $(head -c 300 "$W/err.txt")"
    echo "port 80 diizinkan hanya dari CloudFront ($PL)"
  fi
  DNS="$(aws ec2 describe-instances --instance-ids "$(id_server)" --query 'Reservations[0].Instances[0].PublicDnsName' --output text)"
  [ -n "$DNS" ] && [ "$DNS" != None ] || gagal "server tidak punya nama DNS publik"
  # cloudfront-dua-jalur.sh membaca asal API dari berkas bernama alb-dns; di versi Single isinya alamat server ini
  echo "$DNS" > "$W/alb-dns"; echo "asal /api dan /audio untuk CloudFront: $DNS"
}

cloudfront() {
  [ -s "$W/alb-dns" ] || gagal "jalankan dulu: bash 1server.sh buka"
  [ -f "$KODE_DIR/deploy/aws/cloudfront-dua-jalur.sh" ] || gagal "$KODE_DIR belum berisi repositori (git clone, lihat panduan langkah 1)"
  rm -rf "$W/web" && cp -r "$KODE_DIR/web" "$W/web"
  W_DIR="$W" STATE_FILE="$STATE_GAMBAR" WEB_DIR="$W/web" bash "$KODE_DIR/deploy/aws/cloudfront-dua-jalur.sh" "${1:-buat}"
}

hapus() {
  [ "${YA:-}" = "1" ] || { echo "Ini MENGHAPUS server $NAMA dan Security Group $SG_NAMA (juga bucket kode versi lama bila tercatat). Jalankan: YA=1 bash 1server.sh hapus"; return 0; }
  local ID SG B; ID="$(id_server)"; SG="$(cat "$W/sg" 2>/dev/null)"; B="$(cat "$W/bucket" 2>/dev/null)"
  if [ -n "$ID" ]; then
    aws ec2 terminate-instances --instance-ids "$ID" >/dev/null && echo "server $ID dihentikan, menunggu terminated..."
    aws ec2 wait instance-terminated --instance-ids "$ID" && echo "server terminated" && rm -f "$W/instance-id"
  fi
  if [ -n "$SG" ]; then aws ec2 delete-security-group --group-id "$SG" && echo "Security Group dihapus" && rm -f "$W/sg"; fi
  if [ -n "$B" ]; then aws s3 rb "s3://$B" --force >/dev/null && echo "bucket $B dihapus" && rm -f "$W/bucket"; fi
}

set -o pipefail
case "${1:-}" in
  luncurkan|tunggu|bangun|status|naik|memori|verifikasi|buka|hapus) "$1" 2>&1 | bersih ;;
  kode) kode "${2:-}" 2>&1 | bersih ;;
  cloudfront) cloudfront "${2:-}" 2>&1 | bersih ;;
  jalankan) shift; ssm "$*" 2>&1 | bersih ;;
  *) sed -n '2,22p' "$0" ;;
esac
