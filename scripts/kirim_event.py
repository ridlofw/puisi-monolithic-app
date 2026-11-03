"""Terbitkan satu event ke exchange puisi.events, untuk menguji worker tanpa layanan lain.

    python scripts/kirim_event.py puisi.dibuat kontrak/contoh/pantun.json
    python scripts/kirim_event.py puisi.dibuat kontrak/contoh/pantun.json --ulang 30
    python scripts/kirim_event.py puisi.dibuat kontrak/contoh/rusak.json --mentah

Berkas contoh berisi bagian data saja. Script ini membungkusnya dengan amplop dari
kontrak/README.md. --mentah mengirim isi berkas apa adanya, untuk menguji DLQ.
"""
import argparse
import json
import os
import sys
import uuid
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rabbit  # noqa: E402


def amplop(tipe, data, correlation_id):
    return {
        'event_id': str(uuid.uuid4()),
        'tipe': tipe,
        'versi': 1,
        'terjadi_pada': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'correlation_id': correlation_id or str(uuid.uuid4()),
        'data': data,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('routing_key')
    ap.add_argument('berkas')
    ap.add_argument('--mentah', action='store_true', help='kirim isi berkas tanpa amplop')
    ap.add_argument('--correlation-id')
    ap.add_argument('--ulang', type=int, default=1, help='kirim sebanyak n kali, event_id selalu baru')
    ap.add_argument('--event-id', help='pakai event_id tetap, untuk menguji idempotensi')
    a = ap.parse_args()

    with open(a.berkas, encoding='utf-8') as f:
        mentah = f.read()

    for i in range(a.ulang):
        if a.mentah:
            payload = mentah
            cid = a.correlation_id or ''
        else:
            event = amplop(a.routing_key, json.loads(mentah), a.correlation_id)
            if a.event_id:
                event['event_id'] = a.event_id
            payload = json.dumps(event, ensure_ascii=False)
            cid = event['correlation_id']
        hasil = rabbit.panggil('POST', '/exchanges/%s/puisi.events/publish' % rabbit.VHOST, {
            'routing_key': a.routing_key,
            'payload': payload,
            'payload_encoding': 'string',
            'properties': {'content_type': 'application/json', 'delivery_mode': 2,
                           'correlation_id': cid},
        })
        status = 'diteruskan' if hasil.get('routed') else 'TIDAK diteruskan, tidak ada queue yang cocok'
        print('%s %s correlation_id=%s' % (a.routing_key, status, cid or '-'))


if __name__ == '__main__':
    main()
