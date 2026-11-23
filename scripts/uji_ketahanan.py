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


def daftar(nama):
    return http('POST', '/api/auth/register', {'username': nama, 'password': 'rahasia123', 'nama': 'Uji Auth',
                                               'no_id': '0'})


def tahap_pemutus_auth(lap, token):
    # register dipakai karena login dibatasi 10 per menit di gateway
    compose('pause', 'auth-db')
    try:
        hasil = [daftar('pa' + uuid.uuid4().hex[:10]) for _ in range(14)]
    finally:
        compose('unpause', 'auth-db')
    kode = sorted({k for k, _, _, _ in hasil})
    durasi = [d for _, _, _, d in hasil]
    lambat = sum(1 for d in durasi if d > 1.5)
    akhir = sorted(durasi[-6:])[3]
    lap.catat('pemutus-auth-gagal-cepat', kode == [503] and lambat <= 8 and akhir < 0.2,
              'auth-db di-pause: 14 register -> %s, %d lambat > 1,5 s, median 6 terakhir %.0f ms'
              % (kode, lambat, akhir * 1000))
    time.sleep(11)
    pulih = [daftar('pb' + uuid.uuid4().hex[:10])[0] for _ in range(4)]
    lap.catat('pemutus-auth-pulih', pulih[-1] == 201, 'auth-db kembali, register -> %s' % pulih)


def cari(q):
    # parameter _u membuat kunci proxy_cache Nginx unik, supaya yang diuji adalah search-service
    k, b, h, d = http('GET', '/api/search?q=%s&_u=%s' % (q, uuid.uuid4().hex[:8]))
    return k, b or {}, {x.lower(): y for x, y in h.items()}.get('x-cache-layer'), d


def tahap_pemutus_opensearch(lap, token):
    naikkan = lambda: compose('exec', '-T', 'redis', 'redis-cli', 'INCR', 'cari:versi')  # noqa: E731
    naikkan()
    k0, _, lapis0, _ = cari('pinang')
    compose('pause', 'opensearch')
    try:
        naikkan()
        k1, b1, lapis1, _ = cari('pinang')
        lap.catat('pemutus-os-degradasi', k1 == 200 and lapis1 == 'redis-basi' and b1.get('basi') is True,
                  'OpenSearch di-pause, q=pinang -> %s lapis %s (sebelumnya %s dari %s)' % (k1, lapis1, k0, lapis0))
        hasil = [cari('tidakada' + uuid.uuid4().hex[:6]) for _ in range(12)]
    finally:
        compose('unpause', 'opensearch')
    kode = sorted({k for k, _, _, _ in hasil})
    durasi = [d for _, _, _, d in hasil]
    lambat = sum(1 for d in durasi if d > 1.5)
    akhir = sorted(durasi[-6:])[3]
    lap.catat('pemutus-os-gagal-cepat', kode == [503] and lambat <= 8 and akhir < 0.2,
              '12 query tanpa salinan -> %s, %d lambat > 1,5 s, median 6 terakhir %.0f ms'
              % (kode, lambat, akhir * 1000))
    time.sleep(12)
    pulih = [cari('pinang') for _ in range(4)]
    lap.catat('pemutus-os-pulih', pulih[-1][0] == 200 and pulih[-1][2] in ('opensearch', 'redis'),
              'OpenSearch kembali, q=pinang -> %s lapis %s' % (pulih[-1][0], pulih[-1][2]))


def antrean(nama):
    r = subprocess.run([sys.executable, os.path.join(AKAR, 'scripts', 'status_antrian.py')], capture_output=True,
                       text=True)
    for baris in r.stdout.splitlines():
        b = baris.split()
        if b and b[0] == nama:
            return int(b[1]) + int(b[2])
    return -1


def tahap_indeks_paralel(lap, token, jumlah=30, batas=60.0):
    import concurrent.futures
    penanda = 'uji' + uuid.uuid4().hex[:10]
    while antrean('q.pencarian-indeks') > 0:
        time.sleep(1)
    mulai = time.monotonic()

    def kirim(i):
        p = puisi('Indeks %s %d' % (penanda, i))
        p['isi'] = '%s baris pembuka\nbaris kedua nomor %d' % (penanda, i)
        return http('POST', '/api/puisi', p, token, {'Idempotency-Key': str(uuid.uuid4())})[0]

    with concurrent.futures.ThreadPoolExecutor(10) as ex:
        kode = list(ex.map(kirim, range(jumlah)))
    total = 0
    while time.monotonic() - mulai < 240:
        k, b, _, _ = http('GET', '/api/search?q=%s&_u=%s' % (penanda, uuid.uuid4().hex[:6]))
        total = (b or {}).get('total') or 0
        if total >= jumlah and antrean('q.pencarian-indeks') == 0:
            break
        time.sleep(1)
    durasi = time.monotonic() - mulai
    lap.catat('indeks-paralel', kode.count(202) == jumlah and total >= jumlah and durasi < batas,
              '%d puisi (%d event indeks) terindeks dan antrean kosong dalam %.1f s, batas %.0f s'
              % (total, jumlah * 4, durasi, batas))


TAHAP = {
    'idempotensi': tahap_idempotensi,
    'pemutus-db': tahap_pemutus_db,
    'pemutus-auth': tahap_pemutus_auth,
    'pemutus-opensearch': tahap_pemutus_opensearch,
    'indeks-paralel': tahap_indeks_paralel,
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
