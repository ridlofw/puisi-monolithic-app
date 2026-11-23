#!/bin/bash
# EC2 "User data": dijalankan SEKALI oleh AWS saat server pertama kali menyala, sebagai root.
# Tempel isi berkas ini di: Launch instance, Advanced details, User data. Hasilnya: Docker terpasang,
# pengaturan OpenSearch, swap, dan klien NFS siap TANPA masuk ke server satu per satu.
# Dengan ini, pemasangan Docker dan pengaturan server tidak perlu dikerjakan manual di server pekerja (worker).
# (Alternatif bagi `9server.sh luncurkan`, yang memakai User data-nya sendiri dan tidak memanggil berkas ini.)
#
# Untuk Ubuntu Server 24.04. Log: /var/log/puisi-user-data.log  (periksa bila Docker belum ada).
# Server yang akan menjadi MANAGER (tempat men-deploy) tetap perlu kode proyek (lihat docs/PANDUAN-DEPLOY-AWS.md langkah 3).
set -euxo pipefail
exec > /var/log/puisi-user-data.log 2>&1

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git unzip nfs-common

# Docker (cara resmi Docker untuk Ubuntu)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker ubuntu
systemctl enable --now docker

# OpenSearch menolak start bila nilai ini kurang (tidak bisa diatur per container)
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-puisi.conf

# Swap 4 GiB supaya lonjakan memori tidak langsung mematikan container
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "puisi-user-data selesai: $(docker --version)"
