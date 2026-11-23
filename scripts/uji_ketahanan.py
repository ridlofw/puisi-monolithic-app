"""Uji pola ketahanan dan kinerja Bab 10 dan 11 lewat gateway, setiap tahap LULUS atau BELUM.

    python scripts/uji_ketahanan.py                       semua tahap
    python scripts/uji_ketahanan.py --tahap idempotensi   satu tahap, pisahkan dengan koma

Beberapa tahap mematikan container sebentar lewat docker compose lalu menyalakannya lagi,
jadi jalankan dari akar repositori saat stack --profile semua menyala.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

GATEWAY = os.environ.get('GATEWAY', 'http://localhost')
AKAR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def http(metode, path, isi=None, token=None, header=None, timeout=15):
    data = json.dumps(isi).encode('utf-8') if isi is not None else None
    req = urllib.request.Request(GATEWAY + path, data=data, method=metode)
    req.add_header('Content-Type', 'application/json')
    if token:
        req.add_header('Authorization', 'Bearer ' + token)
    for k, v in (header or {}).items():
        req.add_header(k, v)
    mulai = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            badan = res.read()
            return res.status, _json(badan), dict(res.headers), time.monotonic() - mulai
    except urllib.error.HTTPError as e:
        return e.code, _json(e.read()), dict(e.headers), time.monotonic() - mulai
    except (urllib.error.URLError, OSError) as e:
        return 0, {'pesan': str(e)}, {}, time.monotonic() - mulai


def _json(badan):
    try:
        return json.loads(badan) if badan else None
    except ValueError:
        return None


def compose(*args):
    return subprocess.run(['docker', 'compose', '--profile', 'semua'] + list(args), cwd=AKAR,
                          capture_output=True, text=True)


class Laporan(object):
    def __init__(self):
        self.hasil = []

    def catat(self, tahap, lulus, ket):
        self.hasil.append(lulus)
        print('%-22s %-6s %s' % (tahap, 'LULUS' if lulus else 'BELUM', ket), flush=True)
        return lulus


def pengguna_baru():
    nama = 'tahan' + uuid.uuid4().hex[:8]
    http('POST', '/api/auth/register', {'username': nama, 'password': 'rahasia123', 'nama': 'Uji Ketahanan',
                                        'no_id': '0'})
    kode, isi, _, _ = http('POST', '/api/auth/login', {'username': nama, 'password': 'rahasia123'})
    return ((isi or {}).get('data') or {}).get('token') if kode == 200 else None


def puisi(judul):
    return {'judul': judul, 'isi': 'Hujan turun di kota tua\nmembasuh jalan yang lupa nama',
            'tgl_submit': time.strftime('%Y-%m-%d'), 'kategori': '', 'keyword': ''}


def tahap_idempotensi(lap, token):
    kunci = str(uuid.uuid4())
    muatan = puisi('Uji Idempotensi ' + kunci[:8])
    h = {'Idempotency-Key': kunci}
    k1, b1, _, _ = http('POST', '/api/puisi', muatan, token, h)
    k2, b2, hd2, _ = http('POST', '/api/puisi', muatan, token, h)
    id1 = ((b1 or {}).get('data') or {}).get('id')
    id2 = ((b2 or {}).get('data') or {}).get('id')
    replay = {k.lower(): v for k, v in hd2.items()}.get('idempotent-replay')
    lap.catat('idempoten-ulang', k1 == 202 and k2 == 202 and id1 and id1 == id2 and replay == 'true',
              'dua POST kunci sama -> %s %s, id %s dan %s, Idempotent-Replay %s' % (k1, k2, id1, id2, replay))

    muatan_lain = dict(muatan, isi='Isi yang berbeda untuk kunci yang sama')
    k3, b3, _, _ = http('POST', '/api/puisi', muatan_lain, token, h)
    lap.catat('idempoten-konflik', k3 == 409, 'kunci sama isi beda -> %s' % k3)

    k4, _, _, _ = http('POST', '/api/puisi', muatan, token, {'Idempotency-Key': 'x'})
    lap.catat('idempoten-validasi', k4 == 400, 'kunci terlalu pendek -> %s' % k4)

    # sepuluh kiriman kembar bersamaan harus tetap menghasilkan satu puisi
    import concurrent.futures
    kunci2 = str(uuid.uuid4())
    muatan2 = puisi('Uji Kembar ' + kunci2[:8])
    with concurrent.futures.ThreadPoolExecutor(10) as ex:
        hasil = list(ex.map(lambda _: http('POST', '/api/puisi', muatan2, token, {'Idempotency-Key': kunci2}),
                            range(10)))
    ids = {((b or {}).get('data') or {}).get('id') for k, b, _, _ in hasil if k == 202}
    kode = sorted({k for k, _, _, _ in hasil})
    lap.catat('idempoten-bersamaan', len(ids) == 1 and kode == [202],
              '10 POST bersamaan -> kode %s, %d id unik' % (kode, len(ids)))


def tahap_pemutus_db(lap, token):
    # pause membuat koneksi ke Router 1 menggantung sampai timeout 2 s, kasus yang ingin dihindari breaker
    compose('pause', 'poem-db-router-1')
    try:
        durasi, kode = [], []
        for i in range(20):
            k, _, _, d = http('POST', '/api/puisi', puisi('Uji Pemutus %d %s' % (i, uuid.uuid4().hex[:6])), token,
                              {'Idempotency-Key': str(uuid.uuid4())})
            kode.append(k)
            durasi.append(d)
        # tanpa breaker setiap POST menunggu timeout Router 1; dengan breaker hanya 3 kegagalan per
        # replika ditambah probe half-open setiap jeda 10 s yang lambat
        lambat = sum(1 for d in durasi if d > 1.5)
        akhir = sorted(durasi[-10:])[5]
        lap.catat('pemutus-db-gagal-cepat', all(k == 202 for k in kode) and lambat <= 8 and akhir < 0.5,
                  'Router 1 di-pause: 20 POST %s, %d dari 20 lambat > 1,5 s, median 10 terakhir %.0f ms'
                  % ('202' if all(k == 202 for k in kode) else sorted(set(kode)), lambat, akhir * 1000))
    finally:
        compose('unpause', 'poem-db-router-1')
    time.sleep(11)
    for _ in range(4):
        http('POST', '/api/puisi', puisi('Uji Pulih ' + uuid.uuid4().hex[:6]), token,
             {'Idempotency-Key': str(uuid.uuid4())})
    log = compose('logs', '--since', '40s', '--no-log-prefix', 'poem-service').stdout
    lap.catat('pemutus-db-pulih', 'circuit breaker tertutup kembali' in log,
              'Router 1 kembali, half-open lalu closed tercatat di log poem-service')


TAHAP = {
    'idempotensi': tahap_idempotensi,
    'pemutus-db': tahap_pemutus_db,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tahap', default=','.join(TAHAP), help='daftar tahap dipisah koma')
    a = ap.parse_args()
    lap = Laporan()
    token = pengguna_baru()
    if not lap.catat('login', bool(token), 'pengguna uji baru'):
        sys.exit(1)
    for nama in [t.strip() for t in a.tahap.split(',') if t.strip()]:
        TAHAP[nama](lap, token)
    lulus = sum(1 for x in lap.hasil if x)
    print('-- %d dari %d tahap LULUS' % (lulus, len(lap.hasil)))
    sys.exit(0 if lulus == len(lap.hasil) else 1)


if __name__ == '__main__':
    main()
