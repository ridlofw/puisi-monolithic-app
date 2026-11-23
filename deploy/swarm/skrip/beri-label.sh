#!/usr/bin/env bash
# Memasang label penempatan pada satu node Swarm. Jalankan di server manager.
#
#   bash deploy/swarm/skrip/beri-label.sh <nama-node> <pool>[,<pool>...] [slot] [audio]
#
#   pool  : kunci per microservice (infra auto-tagging puisi genre auth tts pencarian emosi)
#           atau singkatan pemilik yang memberi beberapa kunci sekaligus:
#             pison = infra,auto-tagging     ridlo = puisi,genre     ifham = auth,tts
#             evan  = pencarian              ray   = emosi
#   slot  : 1 | 2 | 3   (posisi node klaster di server itu; hanya untuk server pemegang data)
#   audio : kata "audio" bila server ini tempat SeaweedFS (pool tts)
#
# Contoh (satu server per pool, slot 1):
#   bash deploy/swarm/skrip/beri-label.sh ip-172-31-1-10 ridlo 1
#   bash deploy/swarm/skrip/beri-label.sh ip-172-31-1-11 ridlo 2
#   bash deploy/swarm/skrip/beri-label.sh ip-172-31-2-20 ifham 2 audio
#   bash deploy/swarm/skrip/beri-label.sh ip-172-31-1-12 ridlo          # server ekstra (tanpa slot): hanya menambah salinan layanan
# Dipisah penuh per microservice (21 server): pakai kunci, mis.  ... ip-172-31-1-10 puisi 1  dan  ... ip-172-31-1-20 genre
# Sedikit server: satu server boleh beberapa pool, mis.  ... ip-172-31-1-10 pison,ridlo,ifham,evan,ray 1
set -euo pipefail

if [ "$#" -lt 2 ]; then
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

node="$1"; pools="$2"; slot="${3:-}"; audio="${4:-}"
args=()
for p in ${pools//,/ }; do
  case "$p" in
    pison) set -- infra auto-tagging ;;
    ridlo) set -- puisi genre ;;
    ifham) set -- auth tts ;;
    evan)  set -- pencarian ;;
    ray)   set -- emosi ;;
    infra|auto-tagging|puisi|genre|auth|tts|pencarian|emosi) set -- "$p" ;;
    *) echo "pool tidak dikenal: '$p' (kunci: infra auto-tagging puisi genre auth tts pencarian emosi; singkatan: pison ridlo ifham evan ray)" >&2; exit 1 ;;
  esac
  for k in "$@"; do args+=(--label-add "puisi.pool.$k=true"); done
done
if [ -n "$slot" ]; then
  case "$slot" in 1|2|3) args+=(--label-add "puisi.slot=$slot") ;; *) echo "slot harus 1, 2, atau 3" >&2; exit 1 ;; esac
fi
if [ "$audio" = "audio" ]; then args+=(--label-add "puisi.audio=true"); fi

docker node update "${args[@]}" "$node" >/dev/null
echo "label $node: $(docker node inspect "$node" --format '{{.Spec.Labels}}')"
