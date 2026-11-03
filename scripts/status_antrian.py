"""Ringkasan semua queue: jumlah pesan, consumer, dan anggota quorum.

    python scripts/status_antrian.py
    python scripts/status_antrian.py --node     tampilkan juga node klaster
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rabbit  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--node', action='store_true')
    a = ap.parse_args()

    if a.node:
        for n in rabbit.panggil('GET', '/nodes'):
            print('%-20s %s' % (n['name'], 'jalan' if n.get('running') else 'MATI'))
        print()

    print('%-24s %6s %6s %8s  %s' % ('queue', 'siap', 'proses', 'consumer', 'anggota quorum'))
    for q in sorted(rabbit.panggil('GET', '/queues/%s' % rabbit.VHOST), key=lambda q: q['name']):
        anggota = q.get('members') or []
        print('%-24s %6d %6d %8d  %s' % (
            q['name'], q.get('messages_ready', 0), q.get('messages_unacknowledged', 0),
            q.get('consumers', 0), len(anggota)))


if __name__ == '__main__':
    main()
