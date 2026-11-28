#!/usr/bin/env bash
# deploy/aws/9server.sh : membuat 9 server t3.small (Amazon Linux 2023), membentuk klaster Docker Swarm, memasang label,
# membangun image, dan men-deploy stack. Dijalankan dari AWS CloudShell. Server diatur lewat SSM (tanpa kunci SSH).
#
#   Persiapan di CloudShell (sekali): git clone -b <cabang> https://github.com/ridlofw/puisi-monolithic-app.git ~/puisi9/kode
#   bash 9server.sh luncurkan   # 9 server di zona a,b,c + Security Group (user-data: Docker, git, swap 3 GiB)
#   bash 9server.sh swarm       # tunggu SSM, bentuk Swarm (3 manager), pasang label
#   bash 9server.sh kode        # server 1 mengambil kode LANGSUNG dari GitHub (cabang dan commit yang sama dengan ~/puisi9/kode)
#   bash 9server.sh kode a.tgz  # (cara lama / arsip susulan) kirim arsip ke server 1 lewat bucket S3 sementara
#   bash 9server.sh image       # registry + membangun 6 image (di latar belakang); lihat 'bash 9server.sh status'
#   bash 9server.sh deploy      # TAHAP 1: rahasia + docker stack deploy + buang 15 layanan (pencarian dan tts): 28 layanan. Lanjutkan dengan tahap 2
#   bash 9server.sh rabbit      # WAJIB setelah deploy: gabungkan RabbitMQ node 2 dan 3 (tidak otomatis di Swarm), lengkapi anggota antrean quorum. Aman diulang
#   bash 9server.sh gambar      # Lambda + bucket S3 gambar kutipan TANPA distribusi CloudFront sendiri (dibuat sekali oleh 'cloudfront')
#   bash 9server.sh gateway     # image gateway $GATEWAY_TAG (bawaan v4-gw: rentang IP CloudFront, CDN_URL bila ada), rolling update
#   bash 9server.sh cloudfront  # SATU distribusi dua jalur: halaman dari S3, /fungsi ke Lambda, /api dan /audio ke ALB
#   bash 9server.sh jalankan 4 'docker ps'   # perintah apa pun di server nomor 4 lewat SSM
#   bash 9server.sh verifikasi  # klaster MySQL, RabbitMQ (+ anggota antrean quorum), Redis Sentinel, gateway, uji_e2e.py
#   bash 9server.sh redis       # Redis Sentinel: peran tiap node, master menurut tiap Sentinel, TILT
#   bash 9server.sh ujiredis    # uji failover Redis: master di-scale ke 0, Sentinel memilih master baru, node lama kembali sebagai replika
#   bash 9server.sh ujibaru     # tabel idempotensi, Idempotency-Key, throttle 429, memori TTS (untuk kode Bab 10 dan 11 Pison)
#   bash 9server.sh bersihkan   # tampilkan akun dan puisi buatan skrip uji; YA=1 bash 9server.sh bersihkan menghapusnya di semua tempat
#   bash 9server.sh matikan 4   # uji ketahanan: Stop server 4, pemantau + e2e lewat ALB, Start, tunggu pulih (matikan semua = 1 sampai 9 bergantian)
#   bash 9server.sh cek         # node, layanan, memori tiap server
#   (jalankan 'image' TANPA "| tail": tail menahan keluaran sampai perintah selesai; registry bisa 4 menit menarik image pertama)
#   bash 9server.sh status      # log pembangunan image
#   bash 9server.sh hapus       # hapus server dan Security Group yang dibuat skrip ini
#   bash 9server.sh tarik       # tarik image registry ke setiap server sesuai pool-nya, sebelum deploy (DRY=1: hanya cetak rencana, tanpa AWS)
#
# TAG IMAGE (sejak kode Pison Bab 10 dan 11 digabung ke main): semua image dibangun dan dipasang dengan TAG (bawaan v4), gateway final dengan
# GATEWAY_TAG (bawaan ${TAG}-gw). Contoh memperbarui sistem yang berjalan tanpa menimpa image lama (satu-satunya jalan mundur):
#   TAG=v5 bash 9server.sh image; TAG=v5 bash 9server.sh image2; TAG=v5 bash 9server.sh gateway; TAG=v5 bash 9server.sh stack2
# Gunakan TAG yang SAMA di semua perintah itu. Tag lama (v1 sampai v3) adalah milik kode sebelum perubahan Pison.
#
# TAHAP 2 (pencarian + text-to-speech, setelah tahap 1; JANGAN pakai 'deploy' lagi karena ia menghapus layanan itu):
#   bash 9server.sh kode ~/arsip-susulan.tgz   # kirim hanya berkas yang berubah (bukan arsip penuh: lihat komentar di fungsi kode)
#   bash 9server.sh image2                     # bangun puisi-pencarian dan puisi-tts di server 1 (latar belakang)
#   bash 9server.sh stack2                     # stack deploy + deploy/aws/override-9server.yaml; layanan baru menunggu label (0/1)
#   bash 9server.sh pasang pencarian           # vm.max_map_count + label server 1-3 (cabut: bash 9server.sh cabut pencarian)
#   bash 9server.sh pasang tts                 # label server 7-9 (+ puisi.audio di server 7, ubah dengan AUDIO_DI=8). Layanan yang tetap Pending:
#                                              #   docker service update --force --detach puisi_<layanan>   (lihat docs/PANDUAN-DEPLOY-AWS.md bagian Pemecahan masalah)
#   bash 9server.sh memori                     # memori semua server sekaligus
#   bash 9server.sh hitung                     # berapa layanan yang belum penuh (harus 0) dan keadaan node
#
# Susunan (3 server per zona-baris; zona a,b,c). RAM tiap server hanya 2 GiB (batas sandbox). Tahap 1 memasang 28 dari 43 layanan; tahap 2
# melengkapinya menjadi 43 (+ registry = 44 di 'hitung'). Sebelum Redis Sentinel (1 layanan redis) angkanya 23 dari 38 (terbukti 23 dan 24 Nov 2026,
# memori di server 7-9 paling ketat: docs/LAPORAN-EKSPERIMEN-AWS.md bagian 3).
#   s1-s3: infra + auto-tagging + emosi + pencarian (gateway, RabbitMQ 3 node, Redis 3 node + 3 Sentinel, dua worker, OpenSearch)   <- manager Swarm
#   s4-s6: puisi + genre                  (poem-db klaster 3 node + router, poem-service, relay, consumer, genre)
#   s7-s9: auth + tts                     (auth-db dan tts-db klaster 3 node + router, auth-service, SeaweedFS di s7, worker suara)
#
# STATUS: ditulis 23 Nov 2026 dan dijalankan pertama kali di sandbox. Tidak diuji sebelumnya (tidak ada akses AWS di laptop).
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off
REGION="${AWS_REGION:-us-east-1}"; export AWS_REGION="$REGION"
TIPE="${TIPE:-t3.small}"
TAG="${TAG:-v4}"                       # tag semua image (bangun6.sh, bangun2.sh, stack.yaml); jangan menimpa tag lama
GATEWAY_TAG="${GATEWAY_TAG:-${TAG}-gw}"   # gateway final (CDN_URL + rentang IP CloudFront); override-9server.yaml menunjuk tag ini
W="$HOME/puisi9"; mkdir -p "$W"
TSV="$W/servers.tsv"     # nama <tab> instance-id <tab> zona <tab> ip-privat
KODE_DIR="$W/kode"       # salinan repositori di CloudShell (git clone); cabangnya juga diambil server 1 di langkah 'kode'
REPO="${REPO:-https://github.com/ridlofw/puisi-monolithic-app.git}"
STATE_GAMBAR="$W/gambar.state"   # catatan deploy/lambda/siapkan-gambar.sh untuk versi 9 server (versi lama: ~/.puisi-gambar.state)

TATA="1 a infra,auto-tagging,emosi 1
2 b infra,auto-tagging,emosi 2
3 c infra,auto-tagging,emosi 3
4 a puisi,genre 1
5 b puisi,genre 2
6 c puisi,genre 3
7 a auth 1
8 b auth 2
9 c auth 3"
HAPUS_LAYANAN="opensearch opensearch-1 opensearch-2 opensearch-3 opensearch-replika search-consumer search-service seaweedfs text-to-speech tts-audio-init tts-db-1 tts-db-2 tts-db-3 tts-db-cluster-init tts-db-router"

bersih() {
  sed -u -E \
    -e 's/(Encoded authorization failure message:)[[:space:]]*[^[:space:]]+/\1 <disamarkan>/g' \
    -e 's#:(assumed-role|user|role)/([A-Za-z0-9+=,.@_-]+)/[^[:space:]"]+#:\1/\2/<sesi>#g' \
    -e 's/(AROA|AIDA)[A-Z0-9]{12,}:[^"[:space:],]+/\1:<sesi>/g' \
    -e 's/user[0-9]+=[^"[:space:],]+/<sesi>/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
    -e 's/(ASIA|AKIA|AIDA|AROA)[A-Z0-9]{12,}/<id-kunci>/g' \
    -e 's/SWMTKN-1-[A-Za-z0-9-]+/SWMTKN-<disamarkan>/g' \
    -e 's/[0-9]{12}/<akun>/g'
}

id_dari() { awk -F'\t' -v n="puisi-s$1" '$1==n{print $2}' "$TSV"; }
ip_dari() { awk -F'\t' -v n="puisi-s$1" '$1==n{print $4}' "$TSV"; }
gagal() { echo "[GAGAL] $*"; exit 1; }

# ssm <no-server> <perintah>: jalankan di server, cetak stdout (stderr dengan awalan), kode keluar 0 bila Success
ssm() {
  local no="$1"; shift
  local id; id="$(id_dari "$no")"; [ -n "$id" ] || { echo "[GAGAL] server $no tidak ada di $TSV"; return 1; }
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
  [ -n "$err" ] && [ "$err" != "None" ] && echo "[stderr s$no] $err"
  [ "$st" = "Success" ] || { echo "[status ssm s$no: ${st:-tak-diketahui}]"; return 1; }
}

luncurkan() {
  echo "==== 1. Jaringan dan AMI ===="
  local VPC SG AMI
  VPC="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
  [ -n "$VPC" ] && [ "$VPC" != None ] || gagal "VPC bawaan tidak ditemukan"
  SG="$(aws ec2 describe-security-groups --filters Name=group-name,Values=puisi-swarm-sg Name=vpc-id,Values="$VPC" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  if [ -z "$SG" ] || [ "$SG" = None ]; then
    SG="$(aws ec2 create-security-group --group-name puisi-swarm-sg --description "puisi swarm 9 server" --vpc-id "$VPC" --query GroupId --output text)" || gagal "create-security-group"
    aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol -1 --source-group "$SG" >/dev/null || gagal "aturan masuk antar-server"
    echo "Security Group dibuat (semua lalu lintas hanya dari grup itu sendiri)"
  else
    echo "Security Group sudah ada"
  fi
  echo "$SG" > "$W/sg"; echo "$VPC" > "$W/vpc"
  AMI="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)"
  echo "AMI Amazon Linux 2023: $AMI   tipe: $TIPE"

  cat > "$W/user-data.sh" <<'EOF'
#!/bin/bash
exec > /var/log/puisi-user-data.log 2>&1
set -x
dnf install -y docker git
systemctl enable --now docker
fallocate -l 3G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab
mkdir -p /opt/puisi
touch /var/log/puisi-siap
EOF

  echo "==== 2. Meluncurkan 9 server ===="
  local n z pools slot nama sub idl ids=""
  while read -r n z pools slot; do
    nama="puisi-s$n"
    idl="$(aws ec2 describe-instances --filters Name=tag:Name,Values="$nama" Name=instance-state-name,Values=pending,running --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)"
    if [ -n "$idl" ] && [ "$idl" != None ]; then echo "$nama sudah ada ($idl)"; ids="$ids $idl"; continue; fi
    sub="$(aws ec2 describe-subnets --filters Name=availability-zone,Values="${REGION}$z" Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)"
    idl="$(aws ec2 run-instances --image-id "$AMI" --instance-type "$TIPE" --count 1 --subnet-id "$sub" --security-group-ids "$SG" \
      --iam-instance-profile Name=LabInstanceProfile --key-name vockey \
      --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3}' \
      --user-data "file://$W/user-data.sh" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$nama}]" \
      --query 'Instances[0].InstanceId' --output text 2>"$W/err.txt")" \
      || { echo "[GAGAL] meluncurkan $nama: $(head -c 400 "$W/err.txt")"; exit 1; }
    echo "$nama dibuat di zona ${REGION}$z ($idl)"; ids="$ids $idl"
  done <<< "$TATA"

  echo "==== 3. Menunggu semua Running ===="
  aws ec2 wait instance-running --instance-ids $ids || gagal "tidak semua server Running"
  aws ec2 describe-instances --instance-ids $ids \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,Placement.AvailabilityZone,PrivateIpAddress]' --output text | sort -V > "$TSV"
  cat "$TSV" | awk -F'\t' '{printf "%s  %s  %s\n",$1,$3,$4}'
  echo "Selesai: 9 server Running. Langkah berikut: bash 9server.sh swarm   (tunggu 2-3 menit agar Docker dan SSM siap)"
}

swarm() {
  [ -s "$TSV" ] || gagal "belum ada $TSV (jalankan luncurkan)"
  echo "==== 1. Menunggu 9 server terdaftar di SSM (maks 10 menit) ===="
  local i n=0
  for i in $(seq 1 60); do
    n="$(aws ssm describe-instance-information --query 'length(InstanceInformationList[?PingStatus==`Online`])' --output text 2>/dev/null)"
    [ "${n:-0}" -ge 9 ] 2>/dev/null && break; sleep 10
  done
  echo "server online di SSM: ${n:-0}"
  [ "${n:-0}" -ge 9 ] 2>/dev/null || gagal "SSM belum melihat 9 server. Mungkin peran instance tidak punya izin SSM, atau agen belum siap."
  echo "==== 2. Menunggu Docker siap di tiap server ===="
  for i in 1 2 3 4 5 6 7 8 9; do
    printf 's%s: ' "$i"; ssm "$i" "cloud-init status --wait >/dev/null 2>&1; test -f /var/log/puisi-siap && echo \"\$(docker --version | head -1), \$(git --version)\"" || echo "(belum siap)"
  done
  echo "==== 3. Membentuk Swarm ===="
  local S1IP TM TW
  S1IP="$(ip_dari 1)"
  ssm 1 "docker info --format '{{.Swarm.LocalNodeState}}' | grep -qx active || docker swarm init --advertise-addr $S1IP >/dev/null 2>&1; docker info --format 'swarm: {{.Swarm.LocalNodeState}}'"
  TM="$(ssm 1 "docker swarm join-token -q manager" | head -1)"
  TW="$(ssm 1 "docker swarm join-token -q worker" | head -1)"
  [ -n "$TM" ] && [ -n "$TW" ] || gagal "tidak bisa mengambil token Swarm"
  for i in 2 3; do
    printf 's%s (manager): ' "$i"
    ssm "$i" "docker info --format '{{.Swarm.LocalNodeState}}' | grep -qx active && echo sudah-bergabung || (docker swarm join --token $TM --advertise-addr $(ip_dari "$i") $S1IP:2377 2>&1 | tail -1)"
  done
  for i in 4 5 6 7 8 9; do
    printf 's%s (worker): ' "$i"
    ssm "$i" "docker info --format '{{.Swarm.LocalNodeState}}' | grep -qx active && echo sudah-bergabung || (docker swarm join --token $TW --advertise-addr $(ip_dari "$i") $S1IP:2377 2>&1 | tail -1)"
  done
  echo "==== 4. Label ===="
  local no z pools slot node la p
  while read -r no z pools slot; do
    node="$(ssm "$no" "hostname" | head -1)"
    la="--label-add puisi.slot=$slot"
    for p in ${pools//,/ }; do la="$la --label-add puisi.pool.$p=true"; done
    ssm 1 "docker node update $la $node >/dev/null && echo ok" | sed "s/^/s$no ($node) /"
  done <<< "$TATA"
  ssm 1 "docker node ls --format 'table {{.Hostname}}\t{{.Status}}\t{{.ManagerStatus}}'"
  echo "Selesai. Langkah berikut: bash 9server.sh kode   (server 1 mengambil kode dari GitHub)"
}

# kode: tanpa argumen, server 1 mengambil kode LANGSUNG dari GitHub (git clone --depth 1), cabang yang sama dengan salinan di CloudShell
# ($KODE_DIR), ke /opt/puisi. Tidak ada bucket S3 perantara. Sama dengan deploy/aws/1server.sh (terbukti 28 Nov 2026). Bila /opt/puisi sudah
# repositori, langkah ini MENOLAK memperbarui: pada sistem yang berjalan berkas sumber Swarm config/secret tidak boleh berubah isinya
# ("only updates to Labels are allowed"); pakai arsip susulan.
# kode <berkas.tgz>: (cara lama, juga untuk arsip SUSULAN berisi hanya berkas yang berubah) kirim arsip ke server 1 lewat bucket S3 sementara
# dan ekstrak di /opt/puisi. Ekstrak menimpa berkas bernama sama; berkas lain tidak disentuh.
kode() {
  if [ -z "${1:-}" ]; then
    [ -d "$KODE_DIR/.git" ] || gagal "$KODE_DIR belum ada. Jalankan dulu: git clone -b <cabang> $REPO $KODE_DIR"
    local CABANG; CABANG="${CABANG:-$(git -C "$KODE_DIR" rev-parse --abbrev-ref HEAD)}"
    echo "cabang: $CABANG   commit di CloudShell: $(git -C "$KODE_DIR" log -1 --format='%h %s')"
    ssm 1 "set -e; if [ -d /opt/puisi/.git ]; then echo 'sudah ada repositori di /opt/puisi: tidak diubah (pakai arsip susulan)'; else git clone -q --depth 1 -b $CABANG $REPO /opt/puisi.baru && mkdir -p /opt/puisi && cp -a /opt/puisi.baru/. /opt/puisi/ && rm -rf /opt/puisi.baru; fi; cd /opt/puisi && echo \"commit di server 1: \$(git log -1 --format='%h %s')\" && ls deploy/swarm | head -5" \
      || gagal "mengambil kode dari GitHub di server 1"
    return 0
  fi
  local F="$1"
  [ -s "$F" ] || gagal "$F tidak ada (unggah lewat Actions, Upload file)"
  local B N; B="$(cat "$W/bucket" 2>/dev/null)"; N="$(basename "$F")"
  if [ -z "$B" ]; then
    B="puisi-kode-$RANDOM$RANDOM"
    aws s3api create-bucket --bucket "$B" >/dev/null 2>"$W/err.txt" || gagal "membuat bucket: $(head -c 300 "$W/err.txt")"
    echo "$B" > "$W/bucket"
  fi
  aws s3 cp "$F" "s3://$B/$N" >/dev/null || gagal "unggah ke S3"
  echo "$N di S3 ($B). Mengunduh ke server 1..."
  ssm 1 "mkdir -p /opt/puisi && cd /opt/puisi && aws s3 cp s3://$B/$N . --quiet && tar xzf $N && echo diekstrak: $N && ls deploy/swarm | head -5"
}

image() {
  echo "==== Registry (Jalur B) ===="
  # Registry hanya dipasang bila belum ada: memasang ulang pada sistem yang berjalan tidak perlu. Pemeriksaan siap memakai 127.0.0.1 dan batas
  # waktu: `curl http://localhost:5000` di shell SSM mencoba ::1 dulu, dan di AWS (24 Nov 2026) menggantung tanpa akhir (dockerd hanya menahan port
  # itu), sehingga `image` tidak pernah selesai. Docker sendiri (push/pull ke localhost:5000) tetap bekerja.
  ssm 1 "cd /opt/puisi && { docker service inspect registri_registry >/dev/null 2>&1 && echo 'registry sudah ada: tidak dipasang ulang' || docker stack deploy -c deploy/swarm/stack.registry.yaml registri 2>&1 | tail -2; }"
  ssm 1 "for i in \$(seq 1 40); do curl -m 3 -sf http://127.0.0.1:5000/v2/ >/dev/null && echo registry-siap && break; sleep 3; done"
  echo "==== Membangun 6 image di server 1 (latar belakang) ===="
  echo "tag image: $TAG"
  ssm 1 "cd /opt/puisi && : > build.log && (TAG='$TAG' CDN_URL='${CDN_URL:-}' setsid nohup bash deploy/aws/bangun6.sh > build.log 2>&1 < /dev/null &) ; sleep 1; echo mulai"
  echo "Pantau dengan: bash 9server.sh status"
}

status() { ssm 1 "tail -25 /opt/puisi/build.log; echo; docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep localhost | head"; }

deploy() {
  echo "==== Rahasia ===="
  ssm 1 "cd /opt/puisi && python3 scripts/siapkan_rahasia.py >/dev/null && python3 scripts/siapkan_rahasia_auth.py >/dev/null && python3 scripts/siapkan_rahasia_tts.py >/dev/null; ls secrets | wc -l | sed 's/^/jumlah berkas rahasia: /'"
  echo "==== docker stack deploy ===="
  echo "tag image: $TAG"
  ssm 1 "cd /opt/puisi && REGISTRY=localhost:5000 TAG=$TAG docker stack deploy -c deploy/swarm/stack.yaml --with-registry-auth puisi 2>&1 | tail -6"
  echo "==== TAHAP 1: membuang pencarian dan text-to-speech (dipasang lagi di tahap 2: image2, stack2, pasang) ===="
  local s svc=""; for s in $HAPUS_LAYANAN; do svc="$svc puisi_$s"; done
  ssm 1 "docker service rm $svc 2>&1 | tail -3; echo dibuang"
  echo "Pantau: bash 9server.sh cek"
}

cek() {
  echo "==== Node ===="; ssm 1 "docker node ls --format 'table {{.Hostname}}\t{{.Status}}\t{{.Availability}}\t{{.ManagerStatus}}'"
  echo "==== Layanan ===="; ssm 1 "docker service ls --format '{{.Name}}  {{.Mode}}  {{.Replicas}}' | sort"
  echo "==== Memori tiap server (terpakai/total MB, swap terpakai) ===="
  local i
  for i in 1 2 3 4 5 6 7 8 9; do printf 's%s: ' "$i"; SSM_TUNGGU=20 ssm "$i" "free -m | awk 'NR==2{printf \"%s/%s MB  \", \$3, \$2} NR==3{print \"swap \" \$3 \" MB\"}'"; done
}

# RabbitMQ di Swarm: penemuan peer "classic_config" hanya berjalan saat sebuah node PERTAMA KALI dibuat. Node 2 dan 3 menyala
# sebelum node 1 lalu menjadi klaster sendiri, dan "docker service update --force" TIDAK menyatukannya (terbukti di AWS
# 23 Nov 2026, bertentangan dengan catatan lama bahwa itu cukup). Perbaikan yang terbukti: reset node 2 dan 3 (masih
# kosong) lalu join_cluster, kemudian tambah replika antrean quorum. Dijalankan SETELAH deploy dan setelah ketiga rabbitmq 1/1.
# AMAN DIULANG: node yang sudah menjadi anggota klaster DILEWATI. (Tanpa penjaga ini, menjalankannya di sistem yang sudah berklaster
# akan mereset node 2 lalu 3 sebelum replika tumbuh kembali, dan antrean quorum kehilangan mayoritas sesaat.)
rabbit() {
  echo "==== RabbitMQ: gabungkan node 2 dan 3 ke node 1, lalu tambah replika antrean quorum ===="
  local n tumbuh=""
  for n in 2 3; do
    if ssm 1 "docker exec \$(docker ps -qf name=puisi_rabbitmq-1) rabbitmqctl cluster_status 2>&1 | sed -n '/Running Nodes/,/Versions/p' | grep -q rabbit@rabbitmq-$n && echo SUDAH_ANGGOTA" | grep -q SUDAH_ANGGOTA; then
      echo "rabbitmq-$n sudah anggota klaster: dilewati"; continue
    fi
    ssm "$n" "docker exec \$(docker ps -qf name=puisi_rabbitmq-$n) sh -c 'rabbitmqctl stop_app && rabbitmqctl reset && rabbitmqctl join_cluster rabbit@rabbitmq-1 && rabbitmqctl start_app' 2>&1 | tail -3"
    tumbuh="$tumbuh $n"
  done
  for n in $tumbuh; do
    ssm 1 "docker exec \$(docker ps -qf name=puisi_rabbitmq-1) rabbitmq-queues grow rabbit@rabbitmq-$n all 2>&1 | tail -1"
  done
  ssm 1 "docker exec \$(docker ps -qf name=puisi_rabbitmq-1) rabbitmqctl cluster_status 2>&1 | sed -n '/Running Nodes/,/Versions/p' | grep rabbit@"
  kuorum perbaiki
}

# kuorum [perbaiki]: setiap antrean quorum harus beranggota rabbitmq-1, -2, dan -3. Tanpa argumen hanya melapor.
# Dengan 'perbaiki': anggota yang kurang ditambah dengan add_member. Alasannya: 24 Nov 2026 `grow ... all` tidak menambahkan rabbitmq-3 ke
# q.tap (hanya 2 anggota) dan harus diperbaiki manual. Antrean yang baru dideklarasikan sesudah `grow` juga tidak ikut tumbuh.
kuorum() {
  local fix="${1:-}"
  ssm 1 "c=\$(docker ps -qf name=puisi_rabbitmq-1); docker exec \$c rabbitmqctl list_queues -q --no-table-headers name type members 2>/dev/null | awk '\$2==\"quorum\"' > /tmp/kuorum.txt; \
    if [ '$fix' = perbaiki ]; then while read -r q t rest; do for n in 1 2 3; do case \"\$rest\" in *rabbit@rabbitmq-\$n*) ;; *) docker exec \$c rabbitmq-queues add_member -p / \$q rabbit@rabbitmq-\$n 2>&1 | tail -1; echo \"anggota ditambah: \$q <- rabbitmq-\$n\";; esac; done; done < /tmp/kuorum.txt; \
      docker exec \$c rabbitmqctl list_queues -q --no-table-headers name type members 2>/dev/null | awk '\$2==\"quorum\"' > /tmp/kuorum.txt; fi; \
    awk '{n++; if (\$0 ~ /rabbitmq-1/ && \$0 ~ /rabbitmq-2/ && \$0 ~ /rabbitmq-3/) ok++; else print \"KURANG ANGGOTA: \" \$0} END{print ok+0 \" dari \" n+0 \" antrean quorum beranggota 3 node\"}' /tmp/kuorum.txt"
}

# Membangun ulang image gateway final ($GATEWAY_TAG, bawaan ${TAG}-gw): CDN_URL (dari siapkan-gambar.sh) DAN rentang IP CloudFront
# (deploy/swarm/gateway/buat-cloudfront-conf.sh, supaya batas login DAN batas kirim puisi/pencarian dihitung per pengunjung, bukan per edge
# CloudFront), lalu rolling update. Perintah-perintahnya identik dengan yang dijalankan manual di AWS 23 Nov 2026 pada kode sebelum perubahan
# Pison (terbukti: 3 gateway v3, IP di log = IP pengunjung); fungsi ini sendiri belum diuji sebagai skrip.
# Gateway tahap 1 adalah image ${TAG} (hanya CDN_URL). deploy/aws/override-9server.yaml menunjuk $GATEWAY_TAG supaya `stack2` tidak mengembalikannya.
# Tanpa 01-cloudfront.conf (gagal membuatnya), throttle Pison (5 POST/detik dan 30 pencarian/detik per IP) menghitung per EDGE CloudFront,
# bukan per pengunjung; karena itu `&&` di bawah berhenti bila rentang IP gagal dibuat.
# CDN_URL BOLEH kosong (sejak 28 Nov 2026, pola versi Single): dengan SATU distribusi dua jalur (`gambar` lalu `cloudfront`), pengunjung memuat
# halaman dari S3 dan cloudfront-dua-jalur.sh menyisipkan alamat distribusi ke api.js yang diunggah; halaman di dalam image gateway tidak
# dijangkau pengunjung. Rentang IP CloudFront tetap wajib.
gateway() {
  local CDN="${CDN_URL:-$(grep -h '^CDN_URL=' "$STATE_GAMBAR" "$HOME/.puisi-gambar.state" 2>/dev/null | head -1 | cut -d= -f2)}"
  echo "gateway $GATEWAY_TAG dengan CDN_URL=${CDN:-(kosong: halaman dilayani dari S3 lewat distribusi dua jalur)}"
  SSM_TUNGGU=120 ssm 1 "cd /opt/puisi && bash deploy/swarm/gateway/buat-cloudfront-conf.sh && docker build -q --build-arg CDN_URL=$CDN -f deploy/swarm/Dockerfile.gateway -t localhost:5000/puisi-gateway:$GATEWAY_TAG . | tail -1 && docker push -q localhost:5000/puisi-gateway:$GATEWAY_TAG | tail -1 && docker service update --detach --image localhost:5000/puisi-gateway:$GATEWAY_TAG puisi_gateway | tail -1"
}

# Bukti kesehatan klaster dan aplikasi. Disusun dari perintah yang sudah dijalankan manual di AWS; fungsi ini sendiri belum diuji.
verifikasi() {
  echo "==== poem-db (server 4): harus 3 baris ONLINE ===="
  ssm 4 "docker exec \$(docker ps -qf name=puisi_poem-db-1) mysql -uroot -ppoem -N -e 'select member_host,member_state,member_role from performance_schema.replication_group_members' 2>&1 | grep -v Warning"
  echo "==== auth-db (server 7): harus 3 baris ONLINE ===="
  ssm 7 "docker exec \$(docker ps -qf name=puisi_auth-db-1) sh -c 'mysql -uroot -p\$(cat /run/secrets/auth_db_root_password) -N -e \"select member_host,member_state,member_role from performance_schema.replication_group_members\"' 2>&1 | grep -v Warning"
  echo "==== RabbitMQ: harus 3 node, semua antrean quorum beranggota 3 node ===="
  ssm 1 "docker exec \$(docker ps -qf name=puisi_rabbitmq-1) rabbitmqctl cluster_status 2>&1 | sed -n '/Running Nodes/,/Versions/p' | grep rabbit@"
  kuorum
  echo "==== Redis Sentinel: 1 master + 2 replika, ketiga Sentinel sepakat, tilt 0 ===="
  redis
  echo "==== gateway ===="
  ssm 1 "curl -s -o /dev/null -w 'healthz=%{http_code}  ' http://localhost/healthz; curl -s http://localhost/api/puisi/sehat; echo"
  echo "==== uji_e2e.py (8 dari 10 LULUS setelah tahap 1; 10 dari 10 setelah tahap 2) ===="
  SSM_TUNGGU=100 ssm 1 "cd /opt/puisi && GATEWAY=http://localhost python3 scripts/uji_e2e.py --tunggu 150 2>&1 | tail -12"
}

# redis: keadaan Redis Sentinel di Swarm (revisi Hands On 3, S1). Semua pertanyaan dikirim dari container redis-sentinel-1 di server 1 lewat
# nama layanan (jaringan overlay), jadi cukup satu perintah SSM. Yang benar: tepat 1 master dengan connected_slaves:2, dua replika
# master_link_status:up, ketiga Sentinel menyebut master yang sama, sentinel_tilt:0. Juga dicetak puisi:galeri:versi di master (naik setiap
# ada puisi baru: tanda aplikasi menulis ke master yang benar).
redis() {
  ssm 1 "s=\$(docker ps -qf name=puisi_redis-sentinel-1.); [ -n \"\$s\" ] || { echo 'redis-sentinel-1 tidak berjalan di server 1'; exit 1; }; \
    rc() { docker exec \$s redis-cli \"\$@\" 2>&1 | tr -d '\r'; }; : > /tmp/redis.txt; \
    for n in redis-1 redis-2 redis-3; do echo \"\$n: \$(rc -h \$n -p 6379 INFO replication | grep -E '^(role|connected_slaves|master_host|master_link_status):' | tr '\n' ' ')\" | tee -a /tmp/redis.txt; done; \
    for t in redis-sentinel-1 redis-sentinel-2 redis-sentinel-3; do echo \"\$t: master=\$(rc -h \$t -p 26379 SENTINEL get-master-addr-by-name puisi | head -1) \$(rc -h \$t -p 26379 INFO sentinel | grep -E '^sentinel_tilt:')\" | tee -a /tmp/redis.txt; done; \
    m=\$(rc -h redis-sentinel-1 -p 26379 SENTINEL get-master-addr-by-name puisi | head -1); echo \"puisi:galeri:versi di master \$m = \$(rc -h \$m -p 6379 GET puisi:galeri:versi)\"; \
    nm=\$(grep -c 'role:master' /tmp/redis.txt); ns=\$(grep -c 'role:slave.*master_link_status:up' /tmp/redis.txt); \
    nsen=\$(grep '^redis-sentinel' /tmp/redis.txt | sed 's/.*master=\([^ ]*\).*/\1/' | sort -u | wc -l); ntilt=\$(grep -c 'sentinel_tilt:0' /tmp/redis.txt); \
    if [ \"\$nm\" = 1 ] && [ \"\$ns\" = 2 ] && [ \"\$nsen\" = 1 ] && [ \"\$ntilt\" = 3 ]; then echo \"REDIS OK: 1 master (\$m), 2 replika tersambung, 3 Sentinel sepakat, tilt 0\"; else echo \"REDIS PERIKSA: master=\$nm replika-up=\$ns pendapat-sentinel=\$nsen tilt0=\$ntilt\"; fi"
}

# ujiredis: uji failover Redis Sentinel di Swarm tanpa mematikan server (deploy/aws/uji-redis-sentinel.sh, dijalankan di server 1).
# Layanan master di-scale ke 0, Sentinel harus memilih master baru tanpa TILT; lalu di-scale ke 1 dan node lama harus kembali sebagai replika
# (redis/mulai.sh bertanya ke Sentinel lebih dulu). Selama uji, GET /api/puisi lewat gateway lokal sekali per detik.
ujiredis() {
  SSM_TUNGGU=120 ssm 1 "cd /opt/puisi && bash deploy/aws/uji-redis-sentinel.sh"
}

# ===== Pembersih data uji (28 Nov 2026) =====
# Data uji = akun buatan skrip uji SAJA: scripts/uji_e2e.py (username e2e + 8 heksa, nama "Penyair E2E") dan deploy/aws/uji-ketahanan-baru.py
# (username uji + 8 heksa, nama "Penguji Ketahanan"), beserta semua puisi akun itu. Akun dan puisi buatan manusia tidak tersentuh: keduanya
# syarat (pola username DAN nama) harus cocok. Satu puisi tersimpan di beberapa tempat, semuanya dibersihkan:
#   poem-db (puisi, idempotensi), tts-db (job), SeaweedFS (audio/puisi_N.mp3), OpenSearch (indeks puisi), auth-db (users),
#   Redis (versi cache galeri dan pencarian dinaikkan, detail puisi dihapus). Baris outbox yang sudah terkirim dibiarkan (tidak tampil di mana pun).
# Tanpa YA=1 hanya MENAMPILKAN daftar. Jalankan sesudah uji selesai (puisi tidak lagi "diproses"), bukan saat uji berjalan.

# sql_di <no-server> <container> <sandi> <db> <sql>: SQL dikirim lewat base64 dan stdin, supaya tanda kutip tidak rusak di perjalanan SSM.
# <sandi> ditulis literal, mis. 'poem' atau '$(cat /run/secrets/auth_db_root_password)' (dievaluasi di dalam container).
sql_di() {
  local no="$1" wadah="$2" sandi="$3" db="$4" b
  b="$(printf '%s' "$5" | base64 -w0)"
  SSM_TUNGGU=40 ssm "$no" "echo $b | base64 -d | docker exec -i \$(docker ps -qf name=puisi_$wadah.) sh -c 'mysql -uroot -p\"$sandi\" -N -B $db 2>&1 | grep -v \"Using a password\"; true'"
}

# primer <poem|auth|tts>: nomor server pemegang PRIMARY klaster itu (poem-db-N di s(3+N), auth/tts-db-N di s(6+N)).
primer() {
  local kl="$1" dasar sandi h
  case "$kl" in
    poem) dasar=4; sandi='poem' ;;
    auth) dasar=7; sandi='$(cat /run/secrets/auth_db_root_password)' ;;
    tts)  dasar=7; sandi='$(cat /run/secrets/tts_db_root_password)' ;;
  esac
  h="$(sql_di "$dasar" "$kl-db-1" "$sandi" mysql "select member_host from performance_schema.replication_group_members where member_role='PRIMARY'" | grep -oE "$kl-db-[123]" | head -1)"
  [ -n "$h" ] || return 1
  echo $(( dasar + ${h##*-} - 1 )) "$h" "$sandi"
}

bersihkan() {
  local P A T pno pw pnama ano aw anama tno tw tnama uid pid n
  read -r pno pnama pw <<< "$(primer poem)" || true
  read -r ano anama aw <<< "$(primer auth)" || true
  read -r tno tnama tw <<< "$(primer tts)" || true
  [ -n "$pno" ] && [ -n "$ano" ] && [ -n "$tno" ] || gagal "PRIMARY tidak terbaca (poem=$pnama auth=$anama tts=$tnama); jalankan verifikasi dulu"
  echo "PRIMARY: $pnama (s$pno), $anama (s$ano), $tnama (s$tno)"
  echo "==== Akun uji (auth-db) ===="
  A="$(sql_di "$ano" "$anama" "$aw" auth_db "select id, username, nama from users where username regexp '^(e2e|uji)[0-9a-f]{8}\$' and nama in ('Penyair E2E','Penguji Ketahanan') order by id")"
  echo "$A" | sed '/^$/d'
  uid="$(echo "$A" | awk '$1 ~ /^[0-9]+$/ {print $1}' | paste -sd, -)"
  if [ -z "$uid" ]; then echo "Tidak ada data uji. Selesai."; return 0; fi
  # Keluaran SSM dipotong AWS di sekitar 24 000 karakter (terjadi 28 Nov: 1 000+ puisi uji sesudah uji matikan server). Karena itu daftar
  # puisi diringkas per judul, dan semua id diambil dalam SATU baris group_concat, lalu jumlahnya dicocokkan dengan count(*).
  echo "==== Puisi milik akun uji (poem-db), diringkas per judul ===="
  P="$(sql_di "$pno" "$pnama" "$pw" poem_db "select count(*), substring_index(judul, ' ', 2) j, min(id), max(id) from puisi where user_id in ('${uid//,/\',\'}') group by j order by min(id)")"
  echo "$P" | sed '/^$/d' | awk -F'\t' '{printf "%s puisi berjudul \"%s ...\" (id %s sampai %s)\n", $1, $2, $3, $4}'
  pid="$(sql_di "$pno" "$pnama" "$pw" poem_db "set session group_concat_max_len = 4000000; select group_concat(id order by id separator ',') from puisi where user_id in ('${uid//,/\',\'}')" | tr -d '[:space:]' | sed 's/NULL//')"
  n="$(sql_di "$pno" "$pnama" "$pw" poem_db "select count(*) from puisi where user_id in ('${uid//,/\',\'}')" | tr -d '[:space:]')"
  [ "$(echo "${pid:-}" | tr ',' '\n' | sed '/^$/d' | wc -l)" = "${n:-0}" ] || gagal "daftar id puisi tidak lengkap (${n:-?} puisi, id terbaca $(echo "$pid" | tr ',' '\n' | sed '/^$/d' | wc -l)); tidak ada yang dihapus"
  echo "Jumlah: $(echo "$uid" | tr ',' '\n' | wc -l) akun uji, $n puisi uji. Puisi lain tidak disentuh."
  if [ "${YA:-}" != "1" ]; then echo "Belum ada yang dihapus. Untuk menghapus: YA=1 bash 9server.sh bersihkan"; return 0; fi

  if [ -n "$pid" ]; then
    echo "==== tts-db: job suara ===="
    sql_di "$tno" "$tnama" "$tw" tts "delete from job where puisi_id in ($pid); select concat('sisa job: ', count(*)) from job where puisi_id in ($pid)"
    echo "==== SeaweedFS: berkas audio ===="
    local py; py="$(printf '%s' "import boto3
from botocore.config import Config
r=lambda p: open(p).read().strip()
s=boto3.client('s3',endpoint_url='http://seaweedfs:8333',region_name='us-east-1',aws_access_key_id=r('/run/secrets/s3_access_key'),aws_secret_access_key=r('/run/secrets/s3_secret_key'),config=Config(s3={'addressing_style':'path'}))
ids=[$pid]
kunci=['puisi_%d.mp3'%i for i in ids]
for a in range(0, len(kunci), 1000): s.delete_objects(Bucket='audio', Delete={'Objects':[{'Key':k} for k in kunci[a:a+1000]], 'Quiet':True})
cari=set(kunci); ada=0
for hal in s.get_paginator('list_objects_v2').paginate(Bucket='audio'): ada += sum(1 for o in hal.get('Contents',[]) if o['Key'] in cari)
print('audio dihapus untuk %d puisi, sisa: %d' % (len(ids), ada))" | base64 -w0)"
    for n in 7 8 9; do
      SSM_TUNGGU=40 ssm "$n" "c=\$(docker ps -qf name=puisi_text-to-speech.); [ -n \"\$c\" ] && echo $py | base64 -d | docker exec -i \$c python - 2>&1 | tail -3 | sed 's/^/s$n: /'; true"
    done
    echo "==== OpenSearch: dokumen indeks puisi (satu delete_by_query) ===="
    local q; q="$(printf '{"query":{"ids":{"values":[%s]}}}' "$(echo "$pid" | sed 's/[0-9][0-9]*/"&"/g')" | base64 -w0)"
    ssm 1 "c=\$(docker ps -qf name=puisi_opensearch-1.); echo $q | base64 -d | docker exec -i \$c curl -s -XPOST -H 'Content-Type: application/json' --data-binary @- 'localhost:9200/puisi/_delete_by_query?refresh=true' | grep -oE '\"(total|deleted|failures)\":[^,]*' | tr '\n' ' '; echo '(deleted = yang terindeks; sisanya memang tidak pernah terindeks)'"
    echo "==== poem-db: puisi dan idempotensi ===="
    sql_di "$pno" "$pnama" "$pw" poem_db "delete from idempotensi where user_id in ('${uid//,/\',\'}'); delete from puisi where id in ($pid); select concat('sisa puisi uji: ', count(*)) from puisi where id in ($pid)"
  fi
  echo "==== auth-db: akun uji ===="
  sql_di "$ano" "$anama" "$aw" auth_db "delete from users where id in ($uid); select concat('sisa akun uji: ', count(*)) from users where id in ($uid)"
  echo "==== Redis: cache galeri dan pencarian dibuat basi ===="
  # Cache detail per puisi (puisi:detail:N) tidak dihapus satu per satu (bisa ribuan kunci); umurnya hanya 60 detik.
  ssm 1 "s=\$(docker ps -qf name=puisi_redis-sentinel-1.); m=\$(docker exec \$s redis-cli -p 26379 SENTINEL get-master-addr-by-name puisi | head -1); echo \"master \$m: galeri versi \$(docker exec \$s redis-cli -h \$m INCR puisi:galeri:versi), cari versi \$(docker exec \$s redis-cli -h \$m INCR cari:versi)\""
  echo "Selesai. Gateway menyimpan GET /api/puisi 10 detik dan detail puisi 60 detik di Redis; sesudah itu galeri bersih."
}

# ===== Uji matikan satu server (28 Nov 2026) =====
# klaster: anggota ketiga klaster MySQL, dibaca dari node pertama yang hidup (server yang sedang dimatikan, MATI=<no>, dilewati).
klaster() {
  local kl d n s sandi out
  for kl in poem auth tts; do
    case "$kl" in
      poem) d=4; sandi='poem' ;;
      auth) d=7; sandi='$(cat /run/secrets/auth_db_root_password)' ;;
      tts)  d=7; sandi='$(cat /run/secrets/tts_db_root_password)' ;;
    esac
    out=""
    for n in 1 2 3; do
      s=$(( d + n - 1 )); [ "$s" = "${MATI:-0}" ] && continue
      out="$(sql_di "$s" "$kl-db-$n" "$sandi" mysql "select member_host, member_state, member_role from performance_schema.replication_group_members order by member_host")"
      if echo "$out" | grep -q ONLINE; then echo "$kl-db (dibaca dari s$s): $(echo "$out" | grep -E "$kl-db-[123]" | tr '\t' ' ' | paste -sd';' -)"; break; fi
    done
    echo "$out" | grep -q ONLINE || echo "$kl-db: TIDAK TERBACA"
  done
}

# matikan <no|semua>: Stop satu server (bukan Terminate), amati, lalu Start dan tunggu pulih. Selama siklus, CloudShell menjalankan
# deploy/aws/uji-ketahanan-baru.py pantau lewat ALB (1 GET per detik, 1 tulis berkunci tiap 5 detik), dan saat server mati
# scripts/uji_e2e.py dijalankan lewat ALB untuk melihat fitur mana yang tetap jalan. Pulih = `hitung` 44 penuh dan 9 node Ready.
# Data yang dibuat (akun uji, puisi "Uji pantau", "Pagi di Ladang") dihapus sesudahnya dengan `bersihkan`.
matikan() {
  if [ "$1" = semua ]; then local k; for k in 1 2 3 4 5 6 7 8 9; do matikan "$k"; done; return; fi
  local no="$1" id mgr pp i t0 ALB
  id="$(id_dari "$no")"; [ -n "$id" ] || gagal "server $no tidak ada"
  mgr=1; [ "$no" = 1 ] && mgr=2
  ALB="http://$(cat "$W/alb-dns")"
  echo; echo "################ UJI MATIKAN s$no ($id) ################"
  echo "-- sebelum ($(date -u +%T)):"; MGR=$mgr hitung; klaster
  GATEWAY="$ALB" python3 -u "$KODE_DIR/deploy/aws/uji-ketahanan-baru.py" pantau --detik "${PANTAU:-600}" --selang-tulis 5 > "$W/pantau-s$no.log" 2>&1 &
  pp=$!
  sleep 20
  t0=$(date +%s)
  echo "$(date -u +%T) Stop s$no"
  aws ec2 stop-instances --instance-ids "$id" >/dev/null && aws ec2 wait instance-stopped --instance-ids "$id"
  echo "$(date -u +%T) s$no stopped ($(( $(date +%s) - t0 )) detik)"
  sleep 60
  echo "-- saat s$no mati ($(date -u +%T)):"; MGR=$mgr hitung; MATI=$no klaster
  echo "-- uji_e2e.py lewat ALB saat s$no mati:"
  ( cd "$KODE_DIR" && GATEWAY="$ALB" timeout 300 python3 scripts/uji_e2e.py --tunggu 90 2>&1 | tail -11 )
  echo "$(date -u +%T) Start s$no"
  aws ec2 start-instances --instance-ids "$id" >/dev/null && aws ec2 wait instance-running --instance-ids "$id"
  echo "$(date -u +%T) s$no running"
  for i in $(seq 1 40); do
    sleep 15
    if MGR=$mgr hitung 2>&1 | tee "$W/hitung-tmp.txt" | grep -q "44 layanan penuh, 0 belum" && ! grep -qE "Down|Unknown" "$W/hitung-tmp.txt"; then break; fi
  done
  echo "$(date -u +%T) sesudah Start ($(( $(date +%s) - t0 )) detik sejak Stop):"; cat "$W/hitung-tmp.txt"; klaster
  wait "$pp"
  echo "-- pemantau lewat ALB (s$no): $(grep -c . "$W/pantau-s$no.log") baris; bukan 200/202:"
  grep -E 'get=' "$W/pantau-s$no.log" | grep -vE 'get=200 tulis=(-|202)$' | head -15
  grep RINGKASAN "$W/pantau-s$no.log"
}

# Pemeriksaan khusus kode Bab 10 dan 11 (Pison). Jalankan SESUDAH tahap 2 dan `verifikasi` (e2e 10 dari 10 lebih dulu). Dijalankan di AWS 23 Nov 2026 (tabel idempotensi 3/3, uji kunci dan throttle 9 dari 9 lulus, memori TTS terbaca).
#  1) poem-db 3 ONLINE dan tabel `idempotensi` ada di ketiga node. poem-relay membuatnya saat start lewat primary (tereplikasi). Bila relay menyala
#     sebelum klaster terbentuk, tabel bisa mendarat di node mentah; init-cluster.sh lalu jatuh dari `incremental` ke `clone` (yang dicek di sini hasil akhirnya).
#     Penempatan di sini mengikuti docs/bukti-aws/log-cloudshell/penempatan-layanan.txt: poem-db-1 di s4, -2 di s5, -3 di s6 (bila tertulis 0 padahal klaster
#     ONLINE, cek dengan `cek` apakah poem-db-N pindah server).
#  2) Idempotency-Key dan throttle 429 lewat gateway (deploy/aws/uji-ketahanan-baru.py). Uji throttle membuat sekitar 300 POST tanpa token (tidak ada puisi
#     tercipta) dan menunggu 6 detik sesudahnya supaya batas terisi lagi.
#  3) Memori worker suara (1 replika di salah satu server 7 sampai 9; model Piper kini dimuat terus-menerus) dan baris log "voice model loaded".
ujibaru() {
  echo "==== poem-db (server 4): harus 3 baris ONLINE ===="
  ssm 4 "docker exec \$(docker ps -qf name=puisi_poem-db-1) mysql -uroot -ppoem -N -e 'select member_host,member_state,member_role from performance_schema.replication_group_members' 2>&1 | grep -v Warning"
  echo "==== tabel idempotensi di tiap node poem-db (harus 1 di ketiganya) ===="
  local i
  for i in 1 2 3; do
    ssm $((i + 3)) "docker exec \$(docker ps -qf name=puisi_poem-db-$i) mysql -uroot -ppoem -N -e 'show tables from poem_db like \"idempotensi\"' 2>&1 | grep -v Warning | grep -c idempotensi | sed 's/^/poem-db-$i: /'"
  done
  echo "==== Idempotency-Key dan throttle 429 (di server 1, lewat gateway lokal) ===="
  SSM_TUNGGU=60 ssm 1 "cd /opt/puisi && GATEWAY=http://localhost python3 deploy/aws/uji-ketahanan-baru.py semua 2>&1 | tail -20"
  echo "==== worker suara (1 replika di salah satu server 7 sampai 9): memori kontainer dan memori server ===="
  # Swarm bebas memilih server 7, 8, atau 9; hanya server yang benar-benar menjalankannya yang mencetak sesuatu.
  for i in 7 8 9; do
    ssm "$i" "c=\$(docker ps -qf name=puisi_text-to-speech); if [ -n \"\$c\" ]; then echo \"worker suara ada di server $i\"; docker stats --no-stream --format '{{.Name}} memori {{.MemUsage}}' \$c; free -m | awk 'NR==2{printf \"tersedia %s MB dari %s MB; \", \$7, \$2} NR==3{print \"swap \" \$3 \" MB\"}'; fi"
  done
  echo "==== pemanasan model Piper (baris log \"voice model loaded\") ===="
  ssm 1 "docker service logs puisi_text-to-speech 2>&1 | grep -m1 'voice model loaded' | cut -c1-400"
  echo "(Kosong berarti baris pemanasan sudah tergeser dari log, bukan berarti gagal.)"
  echo "Bila memori server worker suara sangat ketat (tersedia kurang dari sekitar 150 MB dan swap terus naik): aktifkan TTS_ENGINE=cli (komentar di override-9server.yaml)."
}

# ===== TAHAP 2: memasang pencarian dan text-to-speech di atas sistem yang SUDAH berjalan (ditambahkan 23 Nov 2026) =====
# Urutan: kode (arsip susulan) -> image2 -> stack2 -> pasang pencarian -> pasang tts. Jangan memakai 'deploy' (ia MENGHAPUS layanan ini).

# Membangun image puisi-pencarian dan puisi-tts di server 1 (latar belakang). Pantau: bash 9server.sh jalankan 1 'cat /opt/puisi/build2.log'
image2() {
  echo "==== Membangun image pencarian dan tts di server 1 (latar belakang) ===="
  echo "tag image: $TAG"
  ssm 1 "cd /opt/puisi && : > build2.log && (TAG='$TAG' setsid nohup bash deploy/aws/bangun2.sh > build2.log 2>&1 < /dev/null &) ; sleep 1; echo mulai"
}

# Ukuran memori semua server sekaligus (paralel): terpakai / tersedia (termasuk cache yang bisa dilepas) / total, swap, dan beban.
memori() {
  local i d; d="$(mktemp -d)"
  for i in 1 2 3 4 5 6 7 8 9; do
    ( SSM_TUNGGU=25 ssm "$i" "free -m | awk 'NR==2{printf \"terpakai %s tersedia %s dari %s MB; \", \$3, \$7, \$2} NR==3{printf \"swap %s MB; \", \$3}'; uptime | sed 's/.*load average/load/'" > "$d/$i" 2>&1 ) &
  done
  wait
  for i in 1 2 3 4 5 6 7 8 9; do printf 's%s: %s\n' "$i" "$(tr '\n' ' ' < "$d/$i")"; done
  rm -rf "$d"
}

# stack2: docker stack deploy dengan override. Tanpa label pool pencarian/tts, layanan baru berstatus 0/1 (menunggu) dan belum memakai memori.
# Sesudahnya dicetak task layanan LAMA yang baru dimulai dalam 5 menit terakhir; harus kosong (artinya tidak ada yang diganti).
# (Itu berlaku bila TAG tidak berubah. Saat memperbarui sistem yang berjalan dengan TAG baru, layanan yang image-nya berganti SENGAJA ikut
#  diganti secara bergulir, jadi daftar itu tidak kosong; yang penting layanan yang tidak ikut berubah, mis. basis data, tidak muncul.)
# Polanya sengaja memakai awalan "Running": pola longgar `[1-5] minutes` ikut cocok dengan "31 minutes" (positif palsu, terjadi di AWS 23 Nov 2026).
# (Jangan membandingkan nomor versi layanan: nomor itu naik untuk SEMUA layanan pada tiap `stack deploy`, walau isinya sama.
#  Itu terbukti di AWS 23 Nov 2026 dan membuat pemeriksaan versi pertama menampilkan semua layanan sebagai "berubah".)
stack2() {
  echo "tag image: $TAG, gateway: $GATEWAY_TAG"
  ssm 1 "cd /opt/puisi && TAG=$TAG GATEWAY_TAG=$GATEWAY_TAG docker stack config -c deploy/swarm/stack.yaml -c deploy/aws/override-9server.yaml 2>&1 | grep -n 'image: .*gateway' "
  ssm 1 "docker service ls --format '{{.Name}}' | sort > /tmp/layanan-sebelum.txt; wc -l < /tmp/layanan-sebelum.txt | sed 's/^/layanan sebelum: /'"
  echo "==== docker stack deploy (stack.yaml + override) ===="
  ssm 1 "cd /opt/puisi && REGISTRY=localhost:5000 TAG=$TAG GATEWAY_TAG=$GATEWAY_TAG docker stack deploy -c deploy/swarm/stack.yaml -c deploy/aws/override-9server.yaml --with-registry-auth puisi 2>&1 | tail -25"
  sleep 20
  echo "==== task layanan lama yang baru dimulai dalam 5 menit terakhir (harus kosong) ===="
  ssm 1 "for s in \$(cat /tmp/layanan-sebelum.txt); do docker service ps \$s --filter desired-state=running --format '{{.Name}} {{.CurrentState}}'; done | grep -E 'Running (less than a second|[0-9]+ seconds|about a minute|[1-5] minutes) ago'; echo selesai-periksa"
}

# label_pool <pool> <no-server...>: pasang label puisi.pool.<pool>=true pada server-server itu (semua dalam satu langkah)
label_pool() {
  local pool="$1"; shift
  local no node
  for no in "$@"; do
    node="$(ssm "$no" "hostname" | head -1)"
    ssm 1 "docker node update --label-add puisi.pool.$pool=true $node >/dev/null && echo ok" | sed "s/^/s$no ($node) label $pool: /"
  done
}

# pasang <pencarian|tts>: siapkan server lalu beri label supaya Swarm menjadwalkan layanannya.
# Cabut kembali dengan: bash 9server.sh cabut <pencarian|tts>
pasang() {
  case "$1" in
    pencarian)
      echo "==== vm.max_map_count = 262144 di server 1 sampai 3 (wajib bagi OpenSearch; bawaan 65530) ===="
      local i
      for i in 1 2 3; do
        ssm "$i" "sysctl -w vm.max_map_count=262144 >/dev/null && echo vm.max_map_count=262144 > /etc/sysctl.d/99-puisi.conf && sysctl -n vm.max_map_count" | sed "s/^/s$i: /"
      done
      label_pool pencarian 1 2 3 ;;
    tts)
      local audio="${AUDIO_DI:-7}"
      label_pool tts 7 8 9
      local node; node="$(ssm "$audio" "hostname" | head -1)"
      ssm 1 "docker node update --label-add puisi.audio=true $node >/dev/null && echo ok" | sed "s/^/s$audio ($node) label audio: /" ;;
    *) echo "Pemakaian: bash 9server.sh pasang pencarian|tts"; return 1 ;;
  esac
}

cabut() {
  case "$1" in
    pencarian) local no node; for no in 1 2 3; do node="$(ssm "$no" hostname | head -1)"; ssm 1 "docker node update --label-rm puisi.pool.pencarian $node >/dev/null && echo dicabut" | sed "s/^/s$no: /"; done ;;
    tts) local no node; for no in 7 8 9; do node="$(ssm "$no" hostname | head -1)"; ssm 1 "docker node update --label-rm puisi.pool.tts --label-rm puisi.audio $node >/dev/null && echo dicabut" | sed "s/^/s$no: /"; done ;;
    *) echo "Pemakaian: bash 9server.sh cabut pencarian|tts"; return 1 ;;
  esac
}

# hitung: berapa layanan yang BELUM penuh (replika sekarang lebih kecil dari yang diminta). Job yang sudah selesai ("0/1 (1/1 completed)")
# dihitung penuh. Jalankan SETELAH memasang apa pun: satu replika yang macet `Pending` (mis. tts-db-router 1/2) tidak kelihatan dari luar.
# Hasil yang benar setelah tahap 2: "44 layanan penuh, 0 belum; total 44" (43 layanan aplikasi + registry) dan 9 node Ready.
# (Sebelum Redis Sentinel: 39. Setelah tahap 1: 29 = 28 + registry.)
hitung() {
  ssm "${MGR:-1}" "docker service ls --format '{{.Name}} {{.Replicas}}' | awk '/completed\)/{ok++; next} {split(\$2,a,\"/\"); if (a[1]==a[2]) ok++; else {bad++; print \"BELUM PENUH: \" \$0}} END{print ok \" layanan penuh, \" bad+0 \" belum; total \" ok+bad}'; docker node ls --format '{{.Status}} {{.ManagerStatus}}' | sort | uniq -c"
}

# gambar: Lambda + bucket S3 gambar kutipan (Hands-on 1) TANPA distribusi CloudFront gambar sendiri; satu-satunya distribusi dibuat oleh
# `cloudfront`. Pola yang sama dengan versi Single (terbukti 28 Nov 2026). LATAR_DIR (bawaan ~/latar) berisi latar1.jpeg dst. dari dosen;
# bila tidak ada, skrip membuat latar pengganti polos.
gambar() {
  [ -f "$KODE_DIR/deploy/lambda/siapkan-gambar.sh" ] || gagal "$KODE_DIR belum berisi repositori (git clone, lihat panduan langkah 1)"
  ( cd "$KODE_DIR" && STATE_FILE="$STATE_GAMBAR" LATAR_DIR="${LATAR_DIR:-$HOME/latar}" TANPA_CLOUDFRONT=1 bash deploy/lambda/siapkan-gambar.sh "${1:-}" )
}

# cloudfront [buat|unggah|status|hapus]: SATU distribusi dua jalur (halaman dari S3, /fungsi ke Lambda, /api dan /audio ke ALB).
# Membutuhkan ~/puisi9/alb-dns (alb.sh buat) dan $STATE_GAMBAR (gambar).
cloudfront() {
  [ -f "$KODE_DIR/deploy/aws/cloudfront-dua-jalur.sh" ] || gagal "$KODE_DIR belum berisi repositori (git clone, lihat panduan langkah 1)"
  rm -rf "$W/web" && cp -r "$KODE_DIR/web" "$W/web"
  W_DIR="$W" STATE_FILE="$STATE_GAMBAR" WEB_DIR="$W/web" bash "$KODE_DIR/deploy/aws/cloudfront-dua-jalur.sh" "${1:-buat}"
}

hapus() {
  [ "${YA:-}" = "1" ] || { echo "Ini MENGHAPUS 9 server, Security Group puisi-swarm-sg, dan bucket kode sementara (bila ada). Jalankan: YA=1 bash 9server.sh hapus"; return 0; }
  local ids; ids="$(awk -F'\t' '{print $2}' "$TSV" 2>/dev/null | tr '\n' ' ')"
  [ -n "$ids" ] && aws ec2 terminate-instances --instance-ids $ids --query 'TerminatingInstances[].CurrentState.Name' --output text && aws ec2 wait instance-terminated --instance-ids $ids && rm -f "$TSV"
  local sg; sg="$(cat "$W/sg" 2>/dev/null)"; [ -n "$sg" ] && aws ec2 delete-security-group --group-id "$sg" && echo "Security Group dihapus" && rm -f "$W/sg"
  local b; b="$(cat "$W/bucket" 2>/dev/null)"; [ -n "$b" ] && aws s3 rb "s3://$b" --force >/dev/null && echo "bucket kode $b dihapus" && rm -f "$W/bucket"
  echo "Selesai."
}

# tarik: revisi Hands On 3 (S3). Registry localhost:5000 hanya ada di server 1. Image ditarik lebih dulu ke setiap server yang
# boleh menjalankannya (pool dari TATA, ditambah pencarian dan tts tahap 2), supaya task yang dijadwal ulang tidak menunggu server 1:
# stack deploy merujuk image lewat digest, dan Swarm tidak menarik ulang image ber-digest yang sudah ada di server itu.
# DRY=1 hanya mencetak rencana dan memeriksa bahwa setiap image registry di stack punya pool; tidak memanggil AWS sama sekali.
POOL_TAHAP2="1 pencarian
2 pencarian
3 pencarian
7 tts
8 tts
9 tts"

image_pool() {  # image registry milik satu pool, sesuai placement di deploy/swarm/stack.yaml
  case "$1" in
    infra)        echo "puisi-gateway:$TAG puisi-gateway:$GATEWAY_TAG" ;;
    auto-tagging) echo "puisi-auto-tagging:$TAG" ;;
    emosi)        echo "puisi-analisis-emosi:$TAG" ;;
    puisi)        echo "puisi-poem:$TAG" ;;
    genre)        echo "puisi-klasifikasi-genre:$TAG" ;;
    auth)         echo "puisi-auth:$TAG" ;;
    pencarian)    echo "puisi-pencarian:$TAG" ;;
    tts)          echo "puisi-tts:$TAG" ;;
  esac
}

image_server() {  # image_server <no-server>: daftar image localhost:5000 untuk server itu
  local p
  for p in $(echo "$TATA" | awk -v n="$1" '$1==n{print $3}' | tr ',' ' ') $(echo "$POOL_TAHAP2" | awk -v n="$1" '$1==n{print $2}'); do
    image_pool "$p"
  done | tr ' ' '\n' | sed '/^$/d; s#^#localhost:5000/#' | sort -u | tr '\n' ' '
}

tarik() {
  local i semua d akar stack
  echo "tag image: $TAG, gateway: $GATEWAY_TAG"
  semua=""
  for i in 1 2 3 4 5 6 7 8 9; do semua="$semua $(image_server "$i")"; done
  akar="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)"
  stack="$akar/deploy/swarm/stack.yaml"
  if [ -f "$stack" ]; then
    # setiap image registry di stack (dan override) harus tertarik ke minimal satu server
    for i in $(cat "$stack" "$akar/deploy/aws/override-9server.yaml" 2>/dev/null | grep -E '^\s*image: .*(REGISTRY|localhost:5000)' \
        | sed -E 's/.*image: *"?//; s/"$//; s#\$\{REGISTRY:-localhost:5000\}#localhost:5000#; s#\$\{GATEWAY_TAG:-[^}]*\}#'"$GATEWAY_TAG"'#; s#\$\{TAG:-[^}]*\}#'"$TAG"'#' | sort -u); do
      case " $semua " in *" $i "*) echo "tercakup  $i" ;; *) echo "[PERINGATAN] tidak ditarik ke server mana pun: $i" ;; esac
    done
  fi
  if [ "${DRY:-0}" = "1" ]; then
    for i in 1 2 3 4 5 6 7 8 9; do echo "s$i: docker pull $(image_server "$i")"; done
    echo "DRY=1: tidak ada perintah yang dikirim ke AWS."
    return 0
  fi
  d="$(mktemp -d)"
  for i in 1 2 3 4 5 6 7 8 9; do
    ( SSM_TUNGGU=200 ssm "$i" "for im in $(image_server "$i"); do docker pull -q \$im >/dev/null 2>&1 && echo \"ok    \$im\" || echo \"GAGAL \$im\"; done" > "$d/$i" 2>&1 ) &
  done
  wait
  for i in 1 2 3 4 5 6 7 8 9; do sed "s/^/s$i: /" "$d/$i"; done
  rm -rf "$d"
}

case "${1:-}" in
  luncurkan) luncurkan 2>&1 | bersih ;;
  tarik)     tarik 2>&1 | bersih ;;
  swarm)     swarm 2>&1 | bersih ;;
  kode)      shift; kode "$@" 2>&1 | bersih ;;     # bash 9server.sh kode [arsip-susulan.tgz]
  image)     image 2>&1 | bersih ;;
  image2)    image2 2>&1 | bersih ;;
  stack2)    stack2 2>&1 | bersih ;;
  pasang)    shift; pasang "$@" 2>&1 | bersih ;;   # bash 9server.sh pasang pencarian|tts
  cabut)     shift; cabut "$@" 2>&1 | bersih ;;
  memori)    memori 2>&1 | bersih ;;
  hitung)    hitung 2>&1 | bersih ;;
  status)    status 2>&1 | bersih ;;
  deploy)    deploy 2>&1 | bersih ;;
  rabbit)    rabbit 2>&1 | bersih ;;
  gateway)   gateway 2>&1 | bersih ;;
  jalankan)  shift; ssm "$@" 2>&1 | bersih ;;      # bash 9server.sh jalankan <no-server> '<perintah>'
  verifikasi) verifikasi 2>&1 | bersih ;;
  ujibaru)   ujibaru 2>&1 | bersih ;;
  redis)     redis 2>&1 | bersih ;;
  bersihkan) bersihkan 2>&1 | bersih ;;
  klaster)   klaster 2>&1 | bersih ;;
  matikan)   shift; matikan "$@" 2>&1 | bersih ;;  # bash 9server.sh matikan <1..9|semua>: Stop, amati, Start, tunggu pulih            # tampilkan data uji; YA=1 bash 9server.sh bersihkan menghapusnya
  ujiredis)  ujiredis 2>&1 | bersih ;;
  kuorum)    shift; kuorum "$@" 2>&1 | bersih ;;    # bash 9server.sh kuorum [perbaiki]
  gambar)    shift; gambar "$@" 2>&1 | bersih ;;    # bash 9server.sh gambar [hapus]
  cloudfront) shift; cloudfront "$@" 2>&1 | bersih ;;  # bash 9server.sh cloudfront [buat|unggah|status|hapus]
  cek)       cek 2>&1 | bersih ;;
  hapus)     hapus 2>&1 | bersih ;;
  *) sed -n '2,28p' "$0" ;;
esac
