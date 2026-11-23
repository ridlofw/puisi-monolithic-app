#!/usr/bin/env bash
# Pemeriksaan cepat setelah deploy. Jalankan di server MANAGER yang masih hidup,
# dari akar repositori (butuh folder secrets/ untuk sandi klaster auth dan tts).
# `docker exec` hanya menjangkau container di server ini, jadi pemeriksaan database,
# RabbitMQ, dan OpenSearch memakai container sekali pakai yang menempel ke jaringan overlay.
# Skrip ini tetap berguna saat satu server MATI: ia mencoba node satu per satu dan
# melaporkan node pertama yang menjawab.
#   bash deploy/swarm/skrip/cek.sh
set -uo pipefail
cd "$(dirname "$0")/../../.."

NET="${NET:-puisi_puisi}"   # <nama stack>_puisi

echo "##### Node Swarm (normal: semua Ready; tiga manager: satu Leader, dua Reachable)"
docker node ls

echo
echo "##### Kelompok server (pool) per microservice. MINIMAL: infra 3, puisi 3, auth 3, tts 3, pencarian 3, auto-tagging 2, genre 2, emosi 2"
python3 - <<'PY'
import json, subprocess
ids = subprocess.check_output(["docker", "node", "ls", "-q"], text=True).split()
nodes = json.loads(subprocess.check_output(["docker", "node", "inspect"] + ids, text=True))
POOLS = {"infra": 3, "puisi": 3, "auth": 3, "tts": 3, "pencarian": 3, "auto-tagging": 2, "genre": 2, "emosi": 2}
PUNYA_DATA = {"infra", "puisi", "auth", "tts", "pencarian"}   # auto-tagging, genre, emosi: worker tanpa data
tampak = {p: [] for p in POOLS}
for n in nodes:
    lab = n["Spec"].get("Labels", {})
    nama = n["Description"]["Hostname"]
    hidup = n["Status"]["State"] == "ready"
    for p in POOLS:
        if lab.get("puisi.pool." + p) == "true":
            tampak[p].append((nama, lab.get("puisi.slot", "-"), hidup, lab.get("puisi.audio") == "true"))
    if not any(k.startswith("puisi.pool.") for k in lab):
        print("PERINGATAN: node %s tidak punya label puisi.pool.* (tidak akan menjalankan layanan apa pun)" % nama)
for p, minimal in POOLS.items():
    daftar = tampak[p]
    print("pool %-12s: %d server (minimal %d)%s" % (p, len(daftar), minimal, "" if len(daftar) >= minimal else "   <-- KURANG"))
    for nama, slot, hidup, audio in daftar:
        print("    %-26s slot=%s%s%s" % (nama, slot, " audio" if audio else "", "" if hidup else "   (TIDAK ready)"))
    if p in PUNYA_DATA:
        ada = {s for _, s, _, _ in daftar}
        hilang = [s for s in ("1", "2", "3") if s not in ada]
        if hilang:
            print("    <-- slot %s belum ada: layanan berdata pool %s tidak akan start" % (",".join(hilang), p))
    if p == "tts" and not any(a for _, _, _, a in daftar):
        print("    <-- tidak ada server berlabel puisi.audio=true: SeaweedFS tidak akan start")
PY

echo
echo "##### Layanan (kolom REPLICAS harus penuh; job init: 0/1 (1/1 completed); mode global: n/n, n = jumlah server pool pemiliknya)"
docker stack services puisi --format 'table {{.Name}}\t{{.Mode}}\t{{.Replicas}}'

echo
echo "##### Sebaran task (layanan global: SATU per server di pool pemiliknya; layanan klaster: server berbeda di pool pemiliknya)"
docker stack ps puisi --filter desired-state=running --format '{{.Name}}\t{{.Node}}\t{{.CurrentState}}' | sort

# cek_mysql <nama> <sandi-root> <node...>
cek_mysql() {
  local nama="$1" sandi="$2"; shift 2
  echo
  echo "##### InnoDB Cluster $nama (normal: 3 baris ONLINE, 1 PRIMARY)"
  local ok=0 n hasil
  for n in "$@"; do
    hasil=$(docker run --rm --network "$NET" mysql:8.4 \
      mysql --connect-timeout=5 -h "$n" -uroot -p"$sandi" -e \
      "select member_host, member_state, member_role from performance_schema.replication_group_members" 2>/dev/null)
    if [ -n "$hasil" ]; then
      echo "(dijawab oleh $n)"; echo "$hasil"; ok=1; break
    fi
    echo "($n tidak menjawab)"
  done
  [ "$ok" = 1 ] || echo "TIDAK ADA node $nama yang menjawab"
}

cek_mysql poem-db poem poem-db-1 poem-db-2 poem-db-3
if [ -r secrets/auth_db_root_password.txt ]; then
  cek_mysql auth-db "$(tr -d '\r\n' < secrets/auth_db_root_password.txt)" auth-db-1 auth-db-2 auth-db-3
else
  echo; echo "(secrets/auth_db_root_password.txt tidak ada di folder ini: pemeriksaan auth-db dilewati)"
fi
if [ -r secrets/tts_db_root_password.txt ]; then
  cek_mysql tts-db "$(tr -d '\r\n' < secrets/tts_db_root_password.txt)" tts-db-1 tts-db-2 tts-db-3
else
  echo; echo "(secrets/tts_db_root_password.txt tidak ada di folder ini: pemeriksaan tts-db dilewati)"
fi

echo
echo "##### Klaster RabbitMQ (normal: 3 node, running=true)"
ok=0
for n in rabbitmq-1 rabbitmq-2 rabbitmq-3; do
  hasil=$(docker run --rm --network "$NET" alpine sh -c \
    "wget -T 5 -qO- --header \"Authorization: Basic \$(echo -n puisi:puisi | base64)\" http://$n:15672/api/nodes" 2>/dev/null)
  if [ -n "$hasil" ]; then
    echo "(dijawab oleh $n)"
    echo "$hasil" | grep -o '"name":"[^"]*"\|"running":[a-z]*' | paste - -
    ok=1; break
  fi
  echo "($n tidak menjawab)"
done
[ "$ok" = 1 ] || echo "TIDAK ADA node RabbitMQ yang menjawab"

echo
echo "##### Klaster OpenSearch lewat HAProxy (normal: status green, number_of_nodes 3; satu node mati: yellow, 2)"
docker run --rm --network "$NET" alpine sh -c \
  'wget -T 5 -qO- "http://opensearch:9200/_cluster/health?filter_path=status,number_of_nodes" 2>/dev/null || echo "opensearch tidak menjawab"'
echo
echo "replika indeks puisi (normal: number_of_replicas 1; baru muncul setelah indeks dibuat):"
docker run --rm --network "$NET" alpine sh -c \
  'wget -T 5 -qO- "http://opensearch:9200/puisi/_settings?filter_path=*.settings.index.number_of_replicas" 2>/dev/null || echo "(indeks belum ada)"'
echo

echo
echo "##### Gateway di server ini (hanya ada di server pool infra; di server lain hasilnya gagal, itu wajar)"
curl -s -m 5 -o /dev/null -w "GET /healthz -> %{http_code}\n" http://localhost/healthz || true
curl -s -m 5 http://localhost/api/puisi/sehat || true; echo
