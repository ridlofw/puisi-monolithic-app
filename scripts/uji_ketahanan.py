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
    mulai = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            badan = res.read()
            return res.status, _json(badan), dict(res.headers), time.perf_counter() - mulai
    except urllib.error.HTTPError as e:
        return e.code, _json(e.read()), dict(e.headers), time.perf_counter() - mulai
    except (urllib.error.URLError, OSError) as e:
        return 0, {'pesan': str(e)}, {}, time.perf_counter() - mulai


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
    # dihitung, bukan diurutkan: sirkuit bisa mulai dari half-open sisa uji sebelumnya, sehingga probe
    # lambat tidak selalu berada di awal
    lambat = sum(1 for d in durasi if d > 1.5)
    cepat = sum(1 for d in durasi if d < 0.2)
    lap.catat('pemutus-os-gagal-cepat', kode == [503] and lambat <= 6 and cepat >= 6,
              '12 query tanpa salinan -> %s, %d cepat < 200 ms, %d lambat > 1,5 s (tanpa breaker 12 lambat)'
              % (kode, cepat, lambat))
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
    mulai = time.perf_counter()

    def kirim(i):
        p = puisi('Indeks %s %d' % (penanda, i))
        p['isi'] = '%s baris pembuka\nbaris kedua nomor %d' % (penanda, i)
        return http('POST', '/api/puisi', p, token, {'Idempotency-Key': str(uuid.uuid4())})[0]

    with concurrent.futures.ThreadPoolExecutor(10) as ex:
        kode = list(ex.map(kirim, range(jumlah)))
    total = 0
    while time.perf_counter() - mulai < 240:
        k, b, _, _ = http('GET', '/api/search?q=%s&_u=%s' % (penanda, uuid.uuid4().hex[:6]))
        total = (b or {}).get('total') or 0
        if total >= jumlah and antrean('q.pencarian-indeks') == 0:
            break
        time.sleep(1)
    durasi = time.perf_counter() - mulai
    lap.catat('indeks-paralel', kode.count(202) == jumlah and total >= jumlah and durasi < batas,
              '%d puisi (%d event indeks) terindeks dan antrean kosong dalam %.1f s, batas %.0f s'
              % (total, jumlah * 4, durasi, batas))


PENGULANG_VIP = ('i=0; while [ $i -lt 150 ]; do '
                 'if wget -q -T 1 -O /dev/null http://10.231.0.10/sehat-gateway; then echo "$(date +%s.%N) ok"; '
                 'else echo "$(date +%s.%N) gagal"; fi; sleep 0.2; i=$((i+1)); done')


def tahap_gateway_vip(lap, token):
    # klien berada di jaringan gateway-ha dan hanya mengenal VIP, seperti pengguna di depan load balancer
    klien = subprocess.Popen(['docker', 'run', '--rm', '--network', 'puisi_gateway-ha', '--entrypoint', 'sh',
                              'puisi-gateway:lokal', '-c', PENGULANG_VIP],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    time.sleep(6)
    henti = time.time()
    compose('stop', 'gateway')
    time.sleep(12)
    compose('start', 'gateway')
    keluaran, _ = klien.communicate(timeout=120)
    baris = [b.split() for b in keluaran.splitlines() if b.strip()]
    gagal = [float(t) for t, s in baris if s == 'gagal']
    sukses_saat_mati = sum(1 for t, s in baris if s == 'ok' and henti + 1 < float(t) < henti + 12)
    # celah terpanjang = deretan gagal beruntun, dari ok terakhir sebelum gagal sampai ok berikutnya
    celah, mulai_gagal, ok_terakhir = 0.0, None, None
    for t, s in baris:
        t = float(t)
        if s == 'gagal' and mulai_gagal is None:
            mulai_gagal = ok_terakhir if ok_terakhir is not None else t
        elif s == 'ok':
            if mulai_gagal is not None:
                celah = max(celah, t - mulai_gagal)
                mulai_gagal = None
            ok_terakhir = t
    lap.catat('gateway-vip-failover', len(baris) >= 100 and celah < 5 and sukses_saat_mati >= 20,
              '%d request ke VIP, %d gagal, celah terpanjang %.1f s, %d sukses lewat gateway-2 saat gateway-1 mati'
              % (len(baris), len(gagal), celah, sukses_saat_mati))
    k, _, _, _ = http('GET', '/sehat-gateway')
    lap.catat('gateway-vip-kembali', k == 200, 'gateway-1 menyala lagi, port 80 -> %s' % k)


def tahap_throttling(lap, token):
    import concurrent.futures
    with concurrent.futures.ThreadPoolExecutor(40) as ex:
        cari_hasil = list(ex.map(lambda _: cari('kata' + uuid.uuid4().hex[:5]), range(160)))
    kode = [k for k, _, _, _ in cari_hasil]
    pesan = [b.get('pesan', '') for k, b, _, _ in cari_hasil if k == 429]
    lap.catat('throttling-cari', kode.count(429) > 0 and kode.count(200) >= 60 and all('Terlalu banyak' in p for p in pesan),
              '160 pencarian serentak -> %d x 200, %d x 429 JSON' % (kode.count(200), kode.count(429)))
    time.sleep(3)
    with concurrent.futures.ThreadPoolExecutor(20) as ex:
        kirim = list(ex.map(lambda i: http('POST', '/api/puisi', puisi('Throttle %d' % i), token,
                                           {'Idempotency-Key': str(uuid.uuid4())})[0], range(60)))
    lap.catat('throttling-kirim', kirim.count(429) > 0 and kirim.count(202) >= 30,
              '60 kiriman serentak -> %d x 202, %d x 429' % (kirim.count(202), kirim.count(429)))
    time.sleep(2)
    k, _, _, _ = http('GET', '/api/puisi')
    lap.catat('throttling-galeri-bebas', k == 200, 'GET galeri tetap 200 setelah throttling')


TAHAP = {
    'idempotensi': tahap_idempotensi,
    'pemutus-db': tahap_pemutus_db,
    'pemutus-auth': tahap_pemutus_auth,
    'pemutus-opensearch': tahap_pemutus_opensearch,
    'indeks-paralel': tahap_indeks_paralel,
    'gateway-vip': tahap_gateway_vip,
    'throttling': tahap_throttling,
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
