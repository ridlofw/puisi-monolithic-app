#!/usr/bin/env bash
# deploy/swarm/gateway/buat-cloudfront-conf.sh : membuat 01-cloudfront.conf (daftar set_real_ip_from untuk rentang IP CloudFront).
#
# Mengapa: di belakang CloudFront, permintaan sampai ke gateway lewat ALB dengan X-Forwarded-For "IP-pengunjung, IP-edge-CloudFront".
# 00-swarm.conf hanya mempercayai alamat privat, jadi Nginx berhenti di IP edge dan menganggapnya klien. Akibatnya limit_req login
# (10 per menit, kunci = IP klien) dihitung PER EDGE: banyak orang di satu edge berbagi satu ember, dan satu orang yang berpindah
# edge mendapat ember baru. Dengan rentang CloudFront ikut dipercaya, Nginx melewati IP edge dan memakai IP pengunjung.
#
# Aman terhadap pemalsuan: header X-Forwarded-For buatan pengunjung berada di KIRI IP pengunjung yang ditambahkan CloudFront, dan
# real_ip_recursive hanya melewati alamat yang dipercaya (privat + CloudFront), jadi pengunjung tidak bisa memilih IP-nya sendiri.
#
# Dijalankan SEBELUM `docker build` image gateway (deploy/swarm/Dockerfile.gateway menyalin deploy/swarm/gateway/*.conf).
# Butuh internet keluar dan python3 (ada di server Amazon Linux 2023). Rentang CloudFront berubah dari waktu ke waktu; jalankan ulang
# sebelum membangun image gateway baru. Tanpa berkas ini, gateway tetap jalan (hanya batas login per-edge seperti sebelumnya).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
KELUAR="${1:-$DIR/01-cloudfront.conf}"
TMP="$(mktemp)"
curl -fsS --retry 3 https://ip-ranges.amazonaws.com/ip-ranges.json -o "$TMP"
python3 - "$TMP" "$KELUAR" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
v4 = sorted({p['ip_prefix'] for p in d['prefixes'] if p['service'] == 'CLOUDFRONT'})
v6 = sorted({p['ipv6_prefix'] for p in d.get('ipv6_prefixes', []) if p['service'] == 'CLOUDFRONT'})
if len(v4) < 20:
    sys.exit('rentang CloudFront terlalu sedikit (%d); berkas ip-ranges.json berubah bentuk?' % len(v4))
with open(sys.argv[2], 'w') as f:
    f.write('# DIBUAT OTOMATIS oleh buat-cloudfront-conf.sh dari ip-ranges.amazonaws.com (layanan CLOUDFRONT), %d IPv4 dan %d IPv6.\n' % (len(v4), len(v6)))
    f.write('# Jangan disunting; buat ulang. Dipakai bersama 00-swarm.conf (real_ip_header dan real_ip_recursive diatur di sana).\n')
    for c in v4 + v6:
        f.write('set_real_ip_from %s;\n' % c)
print('%s: %d IPv4 + %d IPv6' % (sys.argv[2], len(v4), len(v6)))
EOF
rm -f "$TMP"
