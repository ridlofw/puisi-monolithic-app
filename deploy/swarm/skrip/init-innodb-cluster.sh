#!/bin/sh
# Membentuk (atau memulihkan) InnoDB Cluster 3 node. Versi UMUM dari
# services/puisi/db/init-cluster.sh (milik Ridlo, tidak diubah) supaya auth-db dan tts-db
# bisa memakai pola yang sama. Dijalankan sebagai job Swarm (lihat stack.yaml).
#
# Variabel lingkungan (semuanya wajib kecuali yang bertanda opsional):
#   CLUSTER_NAME        nama klaster, mis. auth_cluster
#   NODES               daftar node dipisah spasi, mis. "auth-db-1 auth-db-2 auth-db-3"
#   ROOT_PASSWORD_FILE  berkas rahasia berisi sandi root (Swarm secret)
#   SCHEMA_FILE         berkas SQL skema; dijalankan di node PRIMARY setelah klaster siap
#   SCHEMA_DB           (opsional) nama database untuk `mysql -D`, bila berkas SQL tidak memakai USE
#
# Aman dijalankan berulang: bila klaster sudah ada, hanya memeriksa dan menyambung ulang anggota.
set -eu

: "${CLUSTER_NAME:?isi CLUSTER_NAME}" "${NODES:?isi NODES}" "${ROOT_PASSWORD_FILE:?isi ROOT_PASSWORD_FILE}" "${SCHEMA_FILE:?isi SCHEMA_FILE}"

PASS="$(tr -d '\r\n' < "$ROOT_PASSWORD_FILE")"
export CLUSTER_NAME NODES
export MYSQL_ROOT_PASSWORD="$PASS"

echo "[cluster-init:$CLUSTER_NAME] Menunggu semua node MySQL siap: $NODES"
for host in $NODES; do
    i=0
    until mysqladmin ping -h "$host" -uroot -p"$PASS" --silent 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -ge 90 ]; then
            echo "[cluster-init:$CLUSTER_NAME] GAGAL: $host tidak merespons setelah 90 percobaan" >&2
            exit 1
        fi
        sleep 2
    done
    echo "[cluster-init:$CLUSTER_NAME] $host siap."
done

echo "[cluster-init:$CLUSTER_NAME] Mengonfigurasi InnoDB Cluster melalui mysqlsh..."
FIRST="${NODES%% *}"
mysqlsh --py --no-wizard --uri="root:${PASS}@${FIRST}:3306" <<'PY'
import os

pw = os.environ['MYSQL_ROOT_PASSWORD']
nama = os.environ['CLUSTER_NAME']
hosts = [h + ':3306' for h in os.environ['NODES'].split()]

for h in hosts:
    try:
        dba.configure_instance('root:%s@%s' % (pw, h))
    except Exception as e:
        print('configure_instance info:', h, e)

cluster = None
for h in hosts:
    try:
        shell.connect('root:%s@%s' % (pw, h))
        cluster = dba.get_cluster(nama)
        print('[cluster-init] Klaster sudah ada (via %s), memeriksa anggota...' % h)
        break
    except Exception:
        pass

if cluster is None:
    shell.connect('root:%s@%s' % (pw, hosts[0]))
    try:
        cluster = dba.reboot_cluster_from_complete_outage(nama)
        print('[cluster-init] Klaster di-reboot dari outage penuh.')
    except Exception:
        print('[cluster-init] Membuat klaster baru %s...' % nama)
        cluster = dba.create_cluster(nama, {'gtidSetIsComplete': True})

topo = cluster.status().get('defaultReplicaSet', {}).get('topology', {})

for h in hosts:
    if h not in topo:
        print('[cluster-init] Menambahkan %s ke klaster...' % h)
        try:
            cluster.add_instance('root:%s@%s' % (pw, h), {'recoveryMethod': 'incremental'})
        except Exception:
            cluster.add_instance('root:%s@%s' % (pw, h), {'recoveryMethod': 'clone'})
    elif topo[h].get('status') != 'ONLINE':
        try:
            cluster.rejoin_instance('root:%s@%s' % (pw, h))
        except Exception as e:
            print('rejoin info:', h, e)

st = cluster.status()['defaultReplicaSet']
print('[cluster-init] Status klaster:', st['status'])
for k, v in st['topology'].items():
    print(' -', k, v.get('status'), v.get('memberRole'), v.get('mode'))
PY

# Skema diterapkan di node PRIMARY saja (super_read_only = 0); GR menyalinnya ke node lain.
# Semua berkas skema memakai CREATE ... IF NOT EXISTS, jadi aman diulang.
echo "[cluster-init:$CLUSTER_NAME] Menerapkan skema di node PRIMARY..."
diterapkan=0
for host in $NODES; do
    RO=$(mysql -h "$host" -uroot -p"$PASS" -N -s -e "SELECT @@super_read_only;" 2>/dev/null || echo "1")
    if [ "$RO" = "0" ]; then
        if [ -n "${SCHEMA_DB:-}" ]; then
            mysql -h "$host" -uroot -p"$PASS" -D "$SCHEMA_DB" < "$SCHEMA_FILE"
        else
            mysql -h "$host" -uroot -p"$PASS" < "$SCHEMA_FILE"
        fi
        echo "[cluster-init:$CLUSTER_NAME] Skema diterapkan lewat $host."
        diterapkan=1
        break
    fi
done
if [ "$diterapkan" != "1" ]; then
    echo "[cluster-init:$CLUSTER_NAME] GAGAL: tidak ada node PRIMARY yang bisa ditulis" >&2
    exit 1
fi

echo "[cluster-init:$CLUSTER_NAME] InnoDB Cluster siap."
