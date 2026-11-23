#!/usr/bin/env bash
# deploy/aws/alb.sh : Application Load Balancer di depan gateway (server 1 sampai 3 menjalankan gateway, mode global).
#   bash alb.sh buat    # Security Group ALB, target group (health check /healthz), ALB internet-facing, listener 80
#   bash alb.sh status  # kesehatan target dan alamat DNS
#   YA=1 bash alb.sh hapus
# Dijalankan di AWS CloudShell setelah 9server.sh luncurkan/swarm/deploy. Memakai ~/puisi9/{vpc,sg,servers.tsv}.
export AWS_PAGER=""
REGION="${AWS_REGION:-us-east-1}"; export AWS_REGION="$REGION"
W="$HOME/puisi9"; TSV="$W/servers.tsv"
VPC="$(cat "$W/vpc" 2>/dev/null)"; SG="$(cat "$W/sg" 2>/dev/null)"
id_dari() { awk -F'\t' -v n="puisi-s$1" '$1==n{print $2}' "$TSV"; }

bersih() {
  sed -u -E \
    -e 's#(assumed-role|user|role)/([A-Za-z0-9+=,.@_-]+)/[^[:space:]"]+#\1/\2/<sesi>#g' \
    -e 's/user[0-9]+=[^"[:space:],]+/<sesi>/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
    -e 's/[0-9]{12}/<akun>/g'
}
gagal() { echo "[GAGAL] $*"; exit 1; }

buat() {
  [ -n "$VPC" ] && [ -n "$SG" ] || gagal "belum ada ~/puisi9/vpc dan sg (jalankan 9server.sh luncurkan)"
  local ASG TG ARN DNS
  ASG="$(aws ec2 describe-security-groups --filters Name=group-name,Values=puisi-alb-sg Name=vpc-id,Values="$VPC" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  if [ -z "$ASG" ] || [ "$ASG" = None ]; then
    ASG="$(aws ec2 create-security-group --group-name puisi-alb-sg --description "puisi alb" --vpc-id "$VPC" --query GroupId --output text)" || gagal "create-security-group ALB"
    aws ec2 authorize-security-group-ingress --group-id "$ASG" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null || gagal "aturan 80 ALB"
    aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 80 --source-group "$ASG" >/dev/null 2>&1
    echo "Security Group ALB dibuat (80 dari internet); server menerima 80 dari ALB"
  else echo "Security Group ALB sudah ada"; fi
  echo "$ASG" > "$W/asg"

  TG="$(aws elbv2 describe-target-groups --names puisi-tg --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)"
  if [ -z "$TG" ] || [ "$TG" = None ]; then
    TG="$(aws elbv2 create-target-group --name puisi-tg --protocol HTTP --port 80 --vpc-id "$VPC" --target-type instance \
      --health-check-protocol HTTP --health-check-path /healthz --health-check-interval-seconds 10 \
      --healthy-threshold-count 2 --unhealthy-threshold-count 2 --query 'TargetGroups[0].TargetGroupArn' --output text 2>"$W/err.txt")" \
      || gagal "create-target-group: $(head -c 300 "$W/err.txt")"
    echo "target group dibuat"
  else echo "target group sudah ada"; fi
  echo "$TG" > "$W/tg"
  aws elbv2 register-targets --target-group-arn "$TG" --targets Id="$(id_dari 1)" Id="$(id_dari 2)" Id="$(id_dari 3)" >/dev/null || gagal "register-targets"
  echo "server 1, 2, 3 didaftarkan sebagai target"

  ARN="$(aws elbv2 describe-load-balancers --names puisi-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)"
  if [ -z "$ARN" ] || [ "$ARN" = None ]; then
    local SUBS
    SUBS="$(for z in a b c; do aws ec2 describe-subnets --filters Name=availability-zone,Values="${REGION}$z" Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text; done | tr '\n' ' ')"
    ARN="$(aws elbv2 create-load-balancer --name puisi-alb --subnets $SUBS --security-groups "$ASG" --scheme internet-facing --type application \
      --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>"$W/err.txt")" || gagal "create-load-balancer: $(head -c 400 "$W/err.txt")"
    aws elbv2 create-listener --load-balancer-arn "$ARN" --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn="$TG" >/dev/null || gagal "create-listener"
    echo "ALB dibuat"
  else echo "ALB sudah ada"; fi
  echo "$ARN" > "$W/alb"
  DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ARN" --query 'LoadBalancers[0].DNSName' --output text)"
  echo "$DNS" > "$W/alb-dns"
  echo "DNS ALB: $DNS"
  echo "Tunggu 1-3 menit sampai target 'healthy', lalu: bash alb.sh status"
}

status() {
  local TG; TG="$(cat "$W/tg" 2>/dev/null)"; [ -n "$TG" ] || gagal "belum ada target group"
  aws elbv2 describe-target-health --target-group-arn "$TG" --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output text
  echo "DNS: $(cat "$W/alb-dns" 2>/dev/null)"
  aws elbv2 describe-load-balancers --names puisi-alb --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null | sed 's/^/status ALB: /'
}

hapus() {
  [ "${YA:-}" = "1" ] || { echo "Ini menghapus ALB, target group, dan Security Group ALB. Jalankan: YA=1 bash alb.sh hapus"; return 0; }
  local ARN TG ASG; ARN="$(cat "$W/alb" 2>/dev/null)"; TG="$(cat "$W/tg" 2>/dev/null)"; ASG="$(cat "$W/asg" 2>/dev/null)"
  [ -n "$ARN" ] && aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" && echo "ALB dihapus (tunggu 1 menit)" && sleep 60
  [ -n "$TG" ] && aws elbv2 delete-target-group --target-group-arn "$TG" && echo "target group dihapus"
  [ -n "$SG" ] && [ -n "$ASG" ] && aws ec2 revoke-security-group-ingress --group-id "$SG" --protocol tcp --port 80 --source-group "$ASG" >/dev/null 2>&1
  [ -n "$ASG" ] && aws ec2 delete-security-group --group-id "$ASG" && echo "Security Group ALB dihapus"
}

case "${1:-buat}" in
  buat) buat 2>&1 | bersih ;;
  status) status 2>&1 | bersih ;;
  hapus) hapus 2>&1 | bersih ;;
  *) sed -n '2,6p' "$0" ;;
esac
