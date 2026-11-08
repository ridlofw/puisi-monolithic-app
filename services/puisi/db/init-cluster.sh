#!/bin/sh
set -eu

PASS="${MYSQL_ROOT_PASSWORD:-poem}"
NODES="poem-db-1 poem-db-2 poem-db-3"

echo "[cluster-init] Menunggu ketiga node MySQL siap..."
for host in $NODES; do
    i=0
    until mysqladmin ping -h "$host" -uroot -p"$PASS" --silent 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -ge 60 ]; then
            echo "[cluster-init] GAGAL: $host tidak merespons setelah 60 percobaan" >&2
            exit 1
        fi
        sleep 2
    done
    RO=$(mysql -h "$host" -uroot -p"$PASS" -N -s -e "SELECT @@super_read_only;" 2>/dev/null || echo "1")
    ADA=$(mysql -h "$host" -uroot -p"$PASS" -N -s -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='poem_db' AND table_name='puisi';" 2>/dev/null || echo "0")
    if [ "$RO" = "0" ] && [ "$ADA" = "0" ]; then
        mysql -h "$host" -uroot -p"$PASS" < /cluster/init.sql
    fi
    echo "[cluster-init] $host siap."
done

echo "[cluster-init] Mengonfigurasi InnoDB Cluster 3-node melalui mysqlsh..."
mysqlsh --py --no-wizard --uri="root:${PASS}@poem-db-1:3306" <<'PY'
import os

pw = os.environ.get('MYSQL_ROOT_PASSWORD', 'poem')
uris = [f'root:{pw}@poem-db-1:3306', f'root:{pw}@poem-db-2:3306', f'root:{pw}@poem-db-3:3306']

for u in uris:
    try:
        dba.configure_instance(u)
    except Exception as e:
        print('configure_instance info:', u, e)

cluster = None
for host in ('poem-db-1:3306', 'poem-db-2:3306', 'poem-db-3:3306'):
    try:
        shell.connect(f'root:{pw}@{host}')
        cluster = dba.get_cluster('puisi_cluster')
        print(f'[cluster-init] Klaster sudah ada (via {host}), memeriksa anggota...')
        break
    except Exception:
        pass

if cluster is None:
    shell.connect(f'root:{pw}@poem-db-1:3306')
    try:
        cluster = dba.reboot_cluster_from_complete_outage('puisi_cluster')
        print('[cluster-init] Klaster di-reboot dari outage penuh.')
    except Exception:
        print('[cluster-init] Membuat klaster baru puisi_cluster...')
        cluster = dba.create_cluster('puisi_cluster', {'gtidSetIsComplete': True})

status = cluster.status()
topo = status.get('defaultReplicaSet', {}).get('topology', {})

for host in ('poem-db-1:3306', 'poem-db-2:3306', 'poem-db-3:3306'):
    if host not in topo:
        print(f'[cluster-init] Menambahkan {host} ke klaster...')
        try:
            cluster.add_instance(f'root:{pw}@{host}', {'recoveryMethod': 'incremental'})
        except Exception:
            cluster.add_instance(f'root:{pw}@{host}', {'recoveryMethod': 'clone'})
    elif topo[host].get('status') != 'ONLINE':
        try:
            cluster.rejoin_instance(f'root:{pw}@{host}')
        except Exception as e:
            print('rejoin info:', host, e)

print('[cluster-init] Status klaster:', cluster.status()['defaultReplicaSet']['status'])
for k, v in cluster.status()['defaultReplicaSet']['topology'].items():
    print(' -', k, v.get('status'), v.get('memberRole'), v.get('mode'))
PY

# Pastikan skema poem_db ada di node Primary
for host in $NODES; do
    RO=$(mysql -h "$host" -uroot -p"$PASS" -N -s -e "SELECT @@super_read_only;" 2>/dev/null || echo "1")
    if [ "$RO" = "0" ]; then
        mysql -h "$host" -uroot -p"$PASS" < /cluster/init.sql || true
        break
    fi
done

echo "[cluster-init] InnoDB Cluster 3-node siap."
