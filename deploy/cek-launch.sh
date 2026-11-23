#!/usr/bin/env bash
# deploy/cek-launch.sh : MENDIAGNOSIS kenapa ec2:RunInstances ditolak di sandbox. HANYA "--dry-run".
# AWS menjawab "akan berhasil / tidak"; TIDAK ADA server yang dibuat, jadi tidak ada biaya.
#
# Latar belakang: cek-sandbox.sh menemukan "UnauthorizedOperation ... explicit deny" untuk t3.large dan t3.medium.
# Skrip ini memisahkan penyebabnya: (1) membaca alasan penolakan, (2) mencoba ukuran dan parameter berbeda.
#
# CARA PAKAI (AWS CloudShell, region us-east-1):  Actions, Upload file, lalu:   bash cek-launch.sh
# Salin SELURUH keluarannya ke percakapan dengan Claude.
#
# PRIVASI: seluruh keluaran lewat bersih() (akun 12 digit, email, nama sesi, ID kunci, blob pesan penolakan).
# STATUS: sintaks diperiksa dan alurnya diuji dengan "aws" palsu yang sengaja membocorkan data palsu.
# BELUM dijalankan di AWS sungguhan.
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

bersih() {
  sed -E \
    -e 's/(Encoded authorization failure message:)[[:space:]]*[^[:space:]]+/\1 <disamarkan>/g' \
    -e 's#(assumed-role|user|role)/([A-Za-z0-9+=,.@_-]+)/[^[:space:]"]+#\1/\2/<sesi>#g' \
    -e 's/(AROA|AIDA)[A-Z0-9]{12,}:[^"[:space:],]+/\1:<sesi>/g' \
    -e 's/user[0-9]+=[^"[:space:],]+/<sesi>/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
    -e 's/(ASIA|AKIA|AIDA|AROA)[A-Z0-9]{12,}/<id-kunci>/g' \
    -e 's/[0-9]{12}/<akun>/g'
}

main() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "aws (AWS CLI) tidak ditemukan. Jalankan skrip ini di AWS CloudShell." >&2; return 1
  fi
  REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null)}}"
  [ -z "$REGION" ] && { echo "Region belum diketahui: export AWS_REGION=us-east-1" >&2; return 1; }

  echo "================ cek-launch $(date -u +%Y-%m-%dT%H:%M:%SZ) ================"
  echo "region : $REGION"

  AMI="$(aws ssm get-parameter --region "$REGION" \
    --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
    --query Parameter.Value --output text 2>/dev/null)"
  # Kunci ke zona "a": t3.large TIDAK ditawarkan di zona "e", dan subnet bawaan pertama bisa saja zona "e".
  ZONA="${ZONA:-${REGION}a}"
  SUBNET="$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=availability-zone,Values=$ZONA" "Name=default-for-az,Values=true" \
    --query 'Subnets[0].SubnetId' --output text 2>/dev/null)"
  echo "ami    : ${AMI:-<tidak ditemukan>}"
  echo "zona   : $ZONA   subnet: ${SUBNET:-<tidak ditemukan>}"
  if [ -z "$AMI" ] || [ "$AMI" = "None" ] || [ -z "$SUBNET" ] || [ "$SUBNET" = "None" ]; then
    echo "AMI atau subnet tidak ditemukan; uji dihentikan."; return 1
  fi

  PESAN=""     # pesan penolakan terenkode pertama, untuk didekode
  LULUS=0; TOLAK=0

  # tes "<label>" <tipe> [argumen run-instances tambahan...]
  tes() {
    local label="$1" tipe="$2"; shift 2
    local out kode sebab
    out="$(aws ec2 run-instances --region "$REGION" --dry-run --image-id "$AMI" --subnet-id "$SUBNET" \
      --count 1 --instance-type "$tipe" "$@" 2>&1)"
    if echo "$out" | grep -q 'DryRunOperation'; then
      echo "[LULUS ] $label"
      LULUS=$((LULUS+1))
    else
      TOLAK=$((TOLAK+1))
      kode="$(echo "$out" | grep -oE '(UnauthorizedOperation|VcpuLimitExceeded|InstanceLimitExceeded|Unsupported|InvalidParameter[A-Za-z]*|InvalidSubnet[A-Za-z.]*|InvalidAMIID[A-Za-z.]*|OptInRequired|[A-Za-z]+Exceeded)' | head -1)"
      sebab="$(echo "$out" | grep -oE 'with an explicit deny in an? [a-z -]+ policy|because no identity-based policy allows[^.]*' | head -1)"
      echo "[DITOLAK] $label"
      echo "          kode: ${kode:-?}   sebab: ${sebab:-?}"
      [ -z "$kode" ] && echo "$out" | head -2 | sed 's/^/          /'
      if [ -z "$PESAN" ]; then
        PESAN="$(echo "$out" | sed -nE 's/.*Encoded authorization failure message:[[:space:]]*([^[:space:]]+).*/\1/p' | head -1)"
      fi
    fi
  }

  IMDS=(--metadata-options HttpTokens=required,HttpEndpoint=enabled)
  DISK=(--block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=30,VolumeType=gp3}')
  PROFIL=(--key-name vockey --iam-instance-profile Name=LabInstanceProfile)
  TAG=(--tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=puisi-uji}]')

  echo
  echo "---- A. Bentuk peluncuran yang dipakai tutorial ----"
  tes "t3.large  bentuk tutorial (key vockey, profil LabInstanceProfile, 30 GiB gp3, IMDSv2)" t3.large "${PROFIL[@]}" "${DISK[@]}" "${IMDS[@]}"
  tes "t3.medium bentuk tutorial" t3.medium "${PROFIL[@]}" "${DISK[@]}" "${IMDS[@]}"

  echo
  echo "---- B. Variasi parameter pada t3.large ----"
  tes "t3.large  polos (tanpa parameter tambahan)" t3.large
  tes "t3.large  + IMDSv2 wajib" t3.large "${IMDS[@]}"
  tes "t3.large  + tag Name" t3.large "${TAG[@]}"
  tes "t3.large  + key vockey" t3.large --key-name vockey
  tes "t3.large  + disk 30 GiB gp3" t3.large "${DISK[@]}"

  echo
  echo "---- C. Ukuran lebih kecil (apakah ukuran dibatasi?) ----"
  for T in t2.micro t3.micro t3.small; do tes "$T polos" "$T"; done

  echo
  echo "---- D. Alasan penolakan (decode-authorization-message) ----"
  if [ -z "$PESAN" ]; then
    echo "(tidak ada pesan penolakan terenkode untuk didekode)"
  else
    d="$(aws sts decode-authorization-message --encoded-message "$PESAN" --query DecodedMessage --output text 2>&1)"
    if [ $? -eq 0 ] && echo "$d" | grep -q '{'; then
      echo "[OK] pesan penolakan berhasil didekode (data pribadi disamarkan):"
      rapi="$(echo "$d" | python3 -m json.tool 2>/dev/null)"
      [ -z "$rapi" ] && rapi="$(echo "$d" | sed -E 's/([,{[])/\1\n/g')"   # cadangan bila python3 tidak ada
      echo "$rapi" | head -150 | sed 's/^/     /'
    else
      echo "[TIDAK BISA] decode-authorization-message ditolak atau gagal:"
      echo "$d" | head -3 | sed 's/^/     /'
    fi
  fi

  echo
  echo "================ RINGKASAN ================"
  echo "dry-run LULUS: $LULUS   DITOLAK: $TOLAK"
  echo "Tempel SELURUH keluaran ini ke percakapan. Tidak ada server yang dibuat."
}

main "$@" 2>&1 | bersih
