#!/usr/bin/env bash
# deploy/cek-sandbox.sh : PEMERIKSAAN SANDBOX AWS. HANYA MEMBACA. Tidak membuat, mengubah, atau menghapus apa pun.
#
# Tujuan: mengetahui apa yang SEBENARNYA diizinkan sandbox Anda, sebelum membuat server. Hasilnya dipakai di
# Langkah 0 docs/PANDUAN-DEPLOY-AWS.md untuk memilih jumlah server, jalur registry, dan cadangan load balancer.
# Untuk mendiagnosis penolakan "ec2:RunInstances", pakai deploy/cek-launch.sh (terpisah).
#
# CARA PAKAI (disarankan: AWS CloudShell, sudah login, tidak perlu mengetik kunci):
#   1. Console AWS, klik ikon CloudShell (>_) di bilah atas. Tunggu terminal terbuka.
#   2. Actions, Upload file, pilih berkas ini. Lalu jalankan:   bash cek-sandbox.sh
#   3. Salin SELURUH keluarannya dan tempel ke percakapan dengan Claude.
#
# PRIVASI: SELURUH keluaran skrip ini disaring oleh fungsi bersih() sebelum tampil: deretan 12 digit (Account ID),
# alamat email, nama sesi pada ARN, ID kunci akses, dan blob "Encoded authorization failure message" diganti penanda.
# (Versi pertama skrip ini hanya menyamarkan hasil sts get-caller-identity, padahal pesan galat AWS ikut mencetak ARN
# lengkap beserta email. Itu sudah diperbaiki dengan menyaring semua keluaran.)
#
# STATUS: sintaks diperiksa (bash -n); alur dan penyaring diuji dengan perintah "aws" palsu yang sengaja
# membocorkan akun/email palsu. Dijalankan di CloudShell sungguhan pada 23 November 2026.
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
    echo "aws (AWS CLI) tidak ditemukan. Jalankan skrip ini di AWS CloudShell." >&2
    return 1
  fi

  REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null)}}"
  if [ -z "$REGION" ]; then
    echo "Region belum diketahui. Jalankan: export AWS_REGION=us-east-1   (ganti dengan region sandbox Anda)" >&2
    return 1
  fi

  OK=(); NO=()

  # coba "<label>" perintah...  : jalankan, cetak hasil ringkas, catat OK atau TIDAK BISA
  coba() {
    local label="$1"; shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [ $rc -eq 0 ]; then
      echo "[OK] $label"
      if [ -n "$out" ] && [ "$out" != "None" ]; then
        echo "$out" | head -25 | sed 's/^/     /'
      else
        echo "     (kosong: perintah berhasil, tetapi tidak ada isi)"
      fi
      OK+=("$label")
    else
      echo "[TIDAK BISA] $label"
      echo "$out" | head -3 | sed 's/^/     /'
      NO+=("$label")
    fi
  }

  echo "================ cek-sandbox $(date -u +%Y-%m-%dT%H:%M:%SZ) ================"
  echo "region : $REGION"
  echo "cli    : $(aws --version 2>&1 | head -1)"

  echo
  echo "---- 1. Siapa saya? ----"
  ACC="$(aws sts get-caller-identity --query Account --output text 2>&1)"
  if echo "$ACC" | grep -Eq '^[0-9]{12}$'; then
    ARN="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"
    echo "[OK] sts get-caller-identity"
    echo "     akun   : ********${ACC: -4}"
    echo "     peran  : $(echo "$ARN" | sed -E 's#^.*:(assumed-role|user|role)/([^/]+).*$#\1/\2#')"
    OK+=("sts get-caller-identity")
  else
    echo "[TIDAK BISA] sts get-caller-identity"
    echo "$ACC" | head -3 | sed 's/^/     /'
    echo "     Tanpa kredensial yang sah, pemeriksaan lain tidak berarti. Berhenti."
    return 1
  fi

  echo
  echo "---- 2. Zona dan subnet (butuh 3 zona untuk uji kegagalan zona) ----"
  coba "subnet per zona (kolom: zona, subnet-bawaan-zona?)" \
    aws ec2 describe-subnets --region "$REGION" --query 'sort_by(Subnets,&AvailabilityZone)[].[AvailabilityZone,DefaultForAz]' --output text
  coba "zona yang tersedia" \
    aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[].ZoneName' --output text

  echo
  echo "---- 3. Ukuran server ----"
  for T in t3.large t3.medium; do
    out="$(aws ec2 describe-instance-type-offerings --region "$REGION" --location-type availability-zone \
      --filters "Name=instance-type,Values=$T" --query 'InstanceTypeOfferings[].Location' --output text 2>&1)"; rc=$?
    if [ $rc -eq 0 ] && [ -n "$out" ] && [ "$out" != "None" ]; then
      echo "[OK] $T ditawarkan di zona: $out"
      OK+=("$T ditawarkan")
    else
      echo "[TIDAK ADA/TIDAK BISA] $T tidak ditawarkan, atau perintahnya ditolak"
      [ $rc -ne 0 ] && echo "$out" | head -3 | sed 's/^/     /'
      NO+=("$T ditawarkan")
    fi
  done

  echo
  echo "---- 4. Server dan sumber daya yang sudah ada ----"
  coba "server yang sudah ada (jumlah, tipe, status)" \
    bash -c "aws ec2 describe-instances --region '$REGION' --filters 'Name=instance-state-name,Values=pending,running,stopping,stopped' --query 'Reservations[].Instances[].[InstanceType,State.Name]' --output text | sort | uniq -c"
  coba "kuota vCPU EC2 (Running On-Demand Standard)" \
    aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value' --output text
  coba "key pair yang ada" \
    aws ec2 describe-key-pairs --region "$REGION" --query 'KeyPairs[].KeyName' --output text
  coba "security group puisi-* yang sudah ada" \
    aws ec2 describe-security-groups --region "$REGION" --filters 'Name=group-name,Values=puisi-*' --query 'SecurityGroups[].GroupName' --output text

  echo
  echo "---- 5. Peran dan profil IAM bawaan sandbox ----"
  coba "peran LabRole" aws iam get-role --role-name LabRole --query 'Role.RoleName' --output text
  coba "instance profile LabInstanceProfile" \
    aws iam get-instance-profile --instance-profile-name LabInstanceProfile --query 'InstanceProfile.InstanceProfileName' --output text

  echo
  echo "---- 6. Layanan untuk deploy (hanya membaca daftar; MEMBUAT belum diuji) ----"
  coba "ECR: daftar repositori" aws ecr describe-repositories --region "$REGION" --query 'repositories[].repositoryName' --output text
  coba "ELB: daftar load balancer" aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerName' --output text
  coba "EFS: daftar sistem berkas" aws efs describe-file-systems --region "$REGION" --query 'FileSystems[].FileSystemId' --output text
  coba "SSM: parameter publik Ubuntu terbaca" \
    aws ssm get-parameter --region "$REGION" --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query 'Parameter.Name' --output text

  echo
  echo "---- 7. Layanan untuk gambar kutipan (Hands-on 1) ----"
  coba "S3: daftar bucket" aws s3api list-buckets --query 'Buckets[].Name' --output text
  coba "Lambda: fungsi yang ada (nama, runtime)" aws lambda list-functions --region "$REGION" --query 'Functions[].[FunctionName,Runtime]' --output text
  coba "CloudFront: distribusi yang ada (id, domain)" aws cloudfront list-distributions --query 'DistributionList.Items[].[Id,DomainName]' --output text

  echo
  echo "================ RINGKASAN ================"
  echo "BISA (${#OK[@]}):"
  for x in "${OK[@]}"; do echo "  + $x"; done
  echo "TIDAK BISA (${#NO[@]}):"
  for x in "${NO[@]}"; do echo "  - $x"; done
  echo
  echo "Catatan: 'BISA' pada daftar (ECR, ELB, S3, ...) hanya berarti MEMBACA diizinkan, bukan MEMBUAT."
  echo "Tempel SELURUH keluaran ini ke percakapan."
}

main "$@" 2>&1 | bersih
