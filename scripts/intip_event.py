"""Baca event dari q.tap, queue pengembangan yang menerima salinan semua event.

    python scripts/intip_event.py               ambil hingga 20 event lalu selesai
    python scripts/intip_event.py --tunggu 15   tunggu sampai 15 detik bila queue masih kosong
    python scripts/intip_event.py --tipe puisi.dianalisis

Event yang sudah dibaca dihapus dari q.tap, jadi setiap pemanggilan hanya menampilkan
event baru. Kosongkan dulu dengan --kosongkan sebelum sebuah uji.
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rabbit  # noqa: E402


def ambil(jumlah):
    return rabbit.panggil('POST', '/queues/%s/q.tap/get' % rabbit.VHOST, {
        'count': jumlah, 'ackmode': 'ack_requeue_false', 'encoding': 'auto'})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--jumlah', type=int, default=20)
    ap.add_argument('--tunggu', type=float, default=0)
    ap.add_argument('--tipe', help='hanya tampilkan routing key ini')
    ap.add_argument('--kosongkan', action='store_true')
    a = ap.parse_args()

    if a.kosongkan:
        rabbit.panggil('DELETE', '/queues/%s/q.tap/contents' % rabbit.VHOST)
        print('q.tap dikosongkan')
        return

    batas = time.time() + a.tunggu
    pesan = ambil(a.jumlah)
    while not pesan and time.time() < batas:
        time.sleep(1)
        pesan = ambil(a.jumlah)

    tampil = 0
    for p in pesan:
        if a.tipe and p['routing_key'] != a.tipe:
            continue
        tampil += 1
        try:
            isi = json.loads(p['payload'])
            print('%s correlation_id=%s event_id=%s' % (
                p['routing_key'], isi.get('correlation_id'), isi.get('event_id')))
            print(json.dumps(isi.get('data'), ensure_ascii=False, indent=2))
        except ValueError:
            print('%s (bukan JSON) %s' % (p['routing_key'], p['payload'][:200]))
    print('-- %d event' % tampil)


if __name__ == '__main__':
    main()
