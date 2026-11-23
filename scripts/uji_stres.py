"""Stress test bertahap lewat gateway untuk mencari titik hancur (Bab 10.5).

    python scripts/uji_stres.py                          tahap bawaan 1 sampai 320 pengguna
    python scripts/uji_stres.py --tahap 5,20 --detik 10
    python scripts/uji_stres.py --json hasil.json        simpan angka mentah

Setiap pengguna virtual mengirim request tanpa jeda, campuran yang mendekati pola baca aplikasi:
50 persen galeri, 25 persen detail puisi, 25 persen pencarian dengan kata acak agar sebagian
tidak tertolong cache. Sebuah tahap dianggap melanggar SLO bila P99 > 500 ms atau galat > 1 persen.
Klien berjalan di mesin yang sama, jadi angka mutlak dibatasi oleh mesin itu; yang dicari adalah
tahap tempat kurva mulai patah.
"""
import argparse
import concurrent.futures
import json
import os
import random
import threading
import time
import urllib.error
import urllib.request

GATEWAY = os.environ.get('GATEWAY', 'http://localhost')
SLO_P99 = 0.5
SLO_GALAT = 0.01
KATA = ['pinang', 'hujan', 'kota', 'padi', 'ladang', 'senja', 'laut', 'rindu', 'bulan', 'angin', 'jalan', 'tua']


def satu_request(maks_id):
    r = random.random()
    if r < 0.5:
        path = '/api/puisi?hal=%d' % random.randint(1, 5)
    elif r < 0.75:
        path = '/api/puisi/%d' % random.randint(1, maks_id)
    else:
        path = '/api/search?q=%s%s' % (random.choice(KATA), random.choice(['', '', str(random.randint(1, 999))]))
    mulai = time.perf_counter()
    try:
        with urllib.request.urlopen(GATEWAY + path, timeout=10) as res:
            res.read()
            kode = res.status
    except urllib.error.HTTPError as e:
        kode = e.code
    except (urllib.error.URLError, OSError):
        kode = 0
    # 404 detail yang id-nya kosong tetap jawaban sah, bukan galat
    return time.perf_counter() - mulai, kode == 0 or kode >= 500


def persentil(nilai, p):
    if not nilai:
        return 0.0
    urut = sorted(nilai)
    return urut[min(len(urut) - 1, int(round(p * (len(urut) - 1))))]


def tahap(pengguna, detik, maks_id):
    durasi, galat = [], 0
    kunci = threading.Lock()
    selesai = time.perf_counter() + detik

    def pekerja():
        nonlocal galat
        while time.perf_counter() < selesai:
            d, g = satu_request(maks_id)
            with kunci:
                durasi.append(d)
                galat += g

    with concurrent.futures.ThreadPoolExecutor(pengguna) as ex:
        for _ in range(pengguna):
            ex.submit(pekerja)
    n = len(durasi)
    hasil = {
        'pengguna': pengguna, 'request': n, 'rps': round(n / detik, 1),
        'p50_ms': round(persentil(durasi, 0.50) * 1000, 1),
        'p95_ms': round(persentil(durasi, 0.95) * 1000, 1),
        'p99_ms': round(persentil(durasi, 0.99) * 1000, 1),
        'galat_persen': round(100.0 * galat / n, 2) if n else 100.0,
    }
    hasil['melanggar_slo'] = hasil['p99_ms'] > SLO_P99 * 1000 or hasil['galat_persen'] > SLO_GALAT * 100
    return hasil


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tahap', default='1,5,10,20,40,80,160,320')
    ap.add_argument('--detik', type=int, default=20)
    ap.add_argument('--json')
    a = ap.parse_args()

    galeri = json.load(urllib.request.urlopen(GATEWAY + '/api/puisi?hal=1', timeout=10))
    maks_id = max([p['id'] for p in (galeri.get('data') or [])] or [1])

    print('%-9s %8s %8s %8s %8s %8s %8s  %s' % ('pengguna', 'request', 'rps', 'P50 ms', 'P95 ms', 'P99 ms',
                                              'galat %', 'SLO'), flush=True)
    semua, patah = [], None
    for n in [int(x) for x in a.tahap.split(',') if x.strip()]:
        h = tahap(n, a.detik, maks_id)
        semua.append(h)
        print('%-9d %8d %8.1f %8.1f %8.1f %8.1f %8.2f  %s' % (
            n, h['request'], h['rps'], h['p50_ms'], h['p95_ms'], h['p99_ms'], h['galat_persen'],
            'LANGGAR' if h['melanggar_slo'] else 'ok'), flush=True)
        if h['melanggar_slo'] and patah is None:
            patah = n
        time.sleep(3)
    terbaik = max(semua, key=lambda h: h['rps'])
    print('-- throughput puncak %.1f rps pada %d pengguna; titik hancur SLO: %s'
          % (terbaik['rps'], terbaik['pengguna'], ('%d pengguna' % patah) if patah else 'tidak tercapai'))
    if a.json:
        with open(a.json, 'w', encoding='utf-8') as f:
            json.dump({'tahap': semua, 'titik_hancur': patah, 'slo_p99_ms': SLO_P99 * 1000}, f, indent=2)


if __name__ == '__main__':
    main()
