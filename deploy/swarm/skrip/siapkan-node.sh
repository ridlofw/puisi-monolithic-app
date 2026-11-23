#!/usr/bin/env bash
# ALTERNATIF MANUAL untuk server yang dibuat tanpa 9server.sh (yang sudah mengatur swap lewat user-data dan vm.max_map_count lewat `pasang pencarian`).
# Jalankan di SETIAP server (EC2) setelah Docker terpasang:
#   sudo bash deploy/swarm/skrip/siapkan-node.sh
# Tidak menyentuh Swarm. Pembentukan Swarm: lihat `swarm()` di deploy/aws/9server.sh.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Jalankan dengan sudo." >&2
  exit 1
fi

# OpenSearch menolak start bila nilai ini kurang. Tidak bisa diatur per container.
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-puisi.conf

# Klien NFS, hanya dipakai bila stack.efs.yaml (data SeaweedFS di Amazon EFS) dipakai. Tidak berbahaya bila tidak.
apt-get install -y nfs-common >/dev/null 2>&1 || echo "peringatan: nfs-common tidak terpasang (hanya perlu untuk stack.efs.yaml)"

# Swap 4 GiB supaya lonjakan memori tidak langsung mematikan container (opsional tapi disarankan)
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo
echo "Docker      : $(docker --version)"
echo "IP privat   : $(hostname -I | awk '{print $1}')   <- pakai ini untuk --advertise-addr"
echo "max_map_count: $(sysctl -n vm.max_map_count)"
free -h | sed -n 1,2p
