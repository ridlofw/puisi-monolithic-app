#!/usr/bin/env bash
# deploy/aws/9server.sh : membuat 9 server t3.small (Amazon Linux 2023), membentuk klaster Docker Swarm, memasang label,
# membangun image, dan men-deploy stack. Dijalankan dari AWS CloudShell. Server diatur lewat SSM (tanpa kunci SSH).
#
#   bash 9server.sh luncurkan   # 9 server di zona a,b,c + Security Group      (butuh ~/kode.tgz untuk langkah 'kode')
#   bash 9server.sh swarm       # tunggu SSM, bentuk Swarm (3 manager), pasang label
#   bash 9server.sh kode        # kirim ~/kode.tgz ke server 1 lewat S3
#   bash 9server.sh image       # registry + membangun 6 image (di latar belakang); lihat 'bash 9server.sh status'
#   bash 9server.sh deploy      # TAHAP 1: rahasia + docker stack deploy + buang 15 layanan (pencarian dan tts). Untuk 38 layanan lanjutkan dengan tahap 2
#   bash 9server.sh rabbit      # WAJIB setelah deploy: gabungkan RabbitMQ node 2 dan 3 (tidak otomatis di Swarm). Aman diulang
#   bash 9server.sh gateway     # image gateway $GATEWAY_TAG (bawaan v4-gw: CDN_URL + rentang IP CloudFront), rolling update
#   bash 9server.sh jalankan 4 'docker ps'   # perintah apa pun di server nomor 4 lewat SSM
#   bash 9server.sh verifikasi  # klaster MySQL, RabbitMQ, gateway, uji_e2e.py
#   bash 9server.sh ujibaru     # tabel idempotensi, Idempotency-Key, throttle 429, memori TTS (untuk kode Bab 10 dan 11 Pison)
#   bash 9server.sh cek         # node, layanan, memori tiap server
#   (jalankan 'image' TANPA "| tail": tail menahan keluaran sampai perintah selesai; registry bisa 4 menit menarik image pertama)
#   bash 9server.sh status      # log pembangunan image
#   bash 9server.sh hapus       # hapus server dan Security Group yang dibuat skrip ini
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
# Susunan (3 server per zona-baris; zona a,b,c). RAM tiap server hanya 2 GiB (batas sandbox). Tahap 1 memasang 23 dari 38 layanan; tahap 2
# melengkapinya menjadi 38 (terbukti 23 Nov 2026, memori di server 7-9 paling ketat: docs/LAPORAN-EKSPERIMEN-AWS.md bagian 3).
#   s1-s3: infra + auto-tagging + emosi + pencarian (gateway, RabbitMQ 3 node, Redis, dua worker, OpenSearch)   <- manager Swarm
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
    -e 's#(assumed-role|user|role)/([A-Za-z0-9+=,.@_-]+)/[^[:space:]"]+#\1/\2/<sesi>#g' \
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
dnf install -y docker
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
    printf 's%s: ' "$i"; ssm "$i" "cloud-init status --wait >/dev/null 2>&1; test -f /var/log/puisi-siap && docker --version | head -1" || echo "(belum siap)"
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
  echo "Selesai. Langkah berikut: unggah kode.tgz ke CloudShell lalu: bash 9server.sh kode"
}

# kode [berkas.tgz]: kirim arsip ke server 1 lewat S3 dan ekstrak di /opt/puisi. Tanpa argumen: ~/kode.tgz (seluruh kode).
# Dengan argumen: arsip SUSULAN (hanya berkas yang berubah). Ekstrak menimpa berkas bernama sama; berkas lain tidak disentuh.
# Jangan mengekstrak arsip penuh baru di atas sistem yang sedang berjalan: berkas yang dipakai Swarm config/secret tidak boleh berubah isinya.
kode() {
  local F="${1:-$HOME/kode.tgz}"
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
}

# Membangun ulang image gateway final ($GATEWAY_TAG, bawaan ${TAG}-gw): CDN_URL (dari siapkan-gambar.sh) DAN rentang IP CloudFront
# (deploy/swarm/gateway/buat-cloudfront-conf.sh, supaya batas login DAN batas kirim puisi/pencarian dihitung per pengunjung, bukan per edge
# CloudFront), lalu rolling update. Perintah-perintahnya identik dengan yang dijalankan manual di AWS 23 Nov 2026 pada kode sebelum perubahan
# Pison (terbukti: 3 gateway v3, IP di log = IP pengunjung); fungsi ini sendiri belum diuji sebagai skrip.
# Gateway tahap 1 adalah image ${TAG} (hanya CDN_URL). deploy/aws/override-9server.yaml menunjuk $GATEWAY_TAG supaya `stack2` tidak mengembalikannya.
# Tanpa 01-cloudfront.conf (gagal membuatnya), throttle Pison (5 POST/detik dan 30 pencarian/detik per IP) menghitung per EDGE CloudFront,
# bukan per pengunjung; karena itu `&&` di bawah berhenti bila rentang IP gagal dibuat.
gateway() {
  local CDN="${CDN_URL:-$(grep '^CDN_URL=' "$HOME/.puisi-gambar.state" 2>/dev/null | cut -d= -f2)}"
  [ -n "$CDN" ] || gagal "CDN_URL kosong: jalankan siapkan-gambar.sh dulu, atau export CDN_URL=https://dxxxx.cloudfront.net"
  echo "gateway $GATEWAY_TAG dengan CDN_URL=$CDN"
  SSM_TUNGGU=120 ssm 1 "cd /opt/puisi && bash deploy/swarm/gateway/buat-cloudfront-conf.sh && docker build -q --build-arg CDN_URL=$CDN -f deploy/swarm/Dockerfile.gateway -t localhost:5000/puisi-gateway:$GATEWAY_TAG . | tail -1 && docker push -q localhost:5000/puisi-gateway:$GATEWAY_TAG | tail -1 && docker service update --detach --image localhost:5000/puisi-gateway:$GATEWAY_TAG puisi_gateway | tail -1"
}

# Bukti kesehatan klaster dan aplikasi. Disusun dari perintah yang sudah dijalankan manual di AWS; fungsi ini sendiri belum diuji.
verifikasi() {
  echo "==== poem-db (server 4): harus 3 baris ONLINE ===="
  ssm 4 "docker exec \$(docker ps -qf name=puisi_poem-db-1) mysql -uroot -ppoem -N -e 'select member_host,member_state,member_role from performance_schema.replication_group_members' 2>&1 | grep -v Warning"
  echo "==== auth-db (server 7): harus 3 baris ONLINE ===="
  ssm 7 "docker exec \$(docker ps -qf name=puisi_auth-db-1) sh -c 'mysql -uroot -p\$(cat /run/secrets/auth_db_root_password) -N -e \"select member_host,member_state,member_role from performance_schema.replication_group_members\"' 2>&1 | grep -v Warning"
  echo "==== RabbitMQ: harus 3 node ===="
  ssm 1 "docker exec \$(docker ps -qf name=puisi_rabbitmq-1) rabbitmqctl cluster_status 2>&1 | sed -n '/Running Nodes/,/Versions/p' | grep rabbit@"
  echo "==== gateway ===="
  ssm 1 "curl -s -o /dev/null -w 'healthz=%{http_code}  ' http://localhost/healthz; curl -s http://localhost/api/puisi/sehat; echo"
  echo "==== uji_e2e.py (8 dari 10 LULUS setelah tahap 1; 10 dari 10 setelah tahap 2) ===="
  SSM_TUNGGU=100 ssm 1 "cd /opt/puisi && GATEWAY=http://localhost python3 scripts/uji_e2e.py --tunggu 150 2>&1 | tail -12"
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
# Hasil yang benar setelah tahap 2: "39 layanan penuh, 0 belum; total 39" (38 layanan aplikasi + registry) dan 9 node Ready.
hitung() {
  ssm 1 "docker service ls --format '{{.Name}} {{.Replicas}}' | awk '/completed\)/{ok++; next} {split(\$2,a,\"/\"); if (a[1]==a[2]) ok++; else {bad++; print \"BELUM PENUH: \" \$0}} END{print ok \" layanan penuh, \" bad+0 \" belum; total \" ok+bad}'; docker node ls --format '{{.Status}} {{.ManagerStatus}}' | sort | uniq -c"
}

hapus() {
  [ "${YA:-}" = "1" ] || { echo "Ini MENGHAPUS 9 server dan Security Group puisi-swarm-sg. Jalankan: YA=1 bash 9server.sh hapus"; return 0; }
  local ids; ids="$(awk -F'\t' '{print $2}' "$TSV" 2>/dev/null | tr '\n' ' ')"
  [ -n "$ids" ] && aws ec2 terminate-instances --instance-ids $ids --query 'TerminatingInstances[].CurrentState.Name' --output text && aws ec2 wait instance-terminated --instance-ids $ids
  local sg; sg="$(cat "$W/sg" 2>/dev/null)"; [ -n "$sg" ] && aws ec2 delete-security-group --group-id "$sg" && echo "Security Group dihapus"
  echo "Selesai."
}

case "${1:-}" in
  luncurkan) luncurkan 2>&1 | bersih ;;
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
  cek)       cek 2>&1 | bersih ;;
  hapus)     hapus 2>&1 | bersih ;;
  *) sed -n '2,19p' "$0" ;;
esac
