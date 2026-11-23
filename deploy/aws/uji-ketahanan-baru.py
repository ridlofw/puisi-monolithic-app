"""Uji tambahan untuk deploy AWS setelah perubahan Bab 10 dan 11 (Pison): Idempotency-Key, throttling gateway, dan pemantau tulis.

    python3 deploy/aws/uji-ketahanan-baru.py idempotensi
    python3 deploy/aws/uji-ketahanan-baru.py throttle
    python3 deploy/aws/uji-ketahanan-baru.py semua
    python3 deploy/aws/uji-ketahanan-baru.py pantau --detik 600 --selang-tulis 5 | tee ~/puisi9/mon-tulis.log

GATEWAY menentukan alamat (bawaan http://localhost, untuk dijalankan di server 1 lewat `bash 9server.sh ujibaru`).
Dari CloudShell: GATEWAY=http://$(cat ~/puisi9/alb-dns) python3 deploy/aws/uji-ketahanan-baru.py pantau

Skrip ini dijalankan di AWS 23 Nov 2026 (idempotensi dan throttle 9 dari 9 lulus; pantau 480 GET dan 96 tulis tanpa gagal saat s6 dimatikan). Hanya memakai pustaka standar Python 3.9 (versi di Amazon Linux 2023).
Satu-satunya perubahan data: akun uji baru dan beberapa puisi uji (judul diawali "Uji ").
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor

GATEWAY = os.environ.get('GATEWAY', 'http://localhost').rstrip('/')


def http(metode, path, isi=None, token=None, header=None, batas=10):
    """Kembalikan (kode, json atau None, header berhuruf kecil). Kode 0 berarti tidak terjangkau."""
    data = json.dumps(isi).encode('utf-8') if isi is not None else None
    req = urllib.request.Request(GATEWAY + path, data=data, method=metode)
    req.add_header('Content-Type', 'application/json')
    if token:
        req.add_header('Authorization', 'Bearer ' + token)
    for k, v in (header or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=batas) as res:
            return res.status, _json(res.read()), {k.lower(): v for k, v in res.headers.items()}
    except urllib.error.HTTPError as e:
        return e.code, _json(e.read()), {k.lower(): v for k, v in e.headers.items()}
    except (urllib.error.URLError, OSError) as e:
        return 0, {'pesan': str(e)}, {}


def _json(badan):
    try:
        return json.loads(badan) if badan else None
    except ValueError:
        return None


class Laporan(object):
    def __init__(self):
        self.baris = []

    def catat(self, nama, lulus, ket):
        self.baris.append((nama, lulus))
        print('%-22s %-6s %s' % (nama, 'LULUS' if lulus else 'GAGAL', ket))
        return lulus

    def ringkas(self):
        lulus = sum(1 for _, ok in self.baris if ok)
        print('-- %d dari %d pemeriksaan LULUS' % (lulus, len(self.baris)))
        return lulus == len(self.baris)


def puisi(judul, isi='Satu baris uji.\nDua baris uji.'):
    return {'judul': judul, 'isi': isi, 'tgl_submit': time.strftime('%Y-%m-%d'), 'kategori': '', 'keyword': ''}


def masuk():
    """Daftar akun uji lalu login; kembalikan token atau None."""
    nama = 'uji' + uuid.uuid4().hex[:8]
    kode, _, _ = http('POST', '/api/auth/register',
                      {'username': nama, 'password': 'rahasia123', 'nama': 'Penguji Ketahanan', 'no_id': '0'})
    if kode not in (200, 201):
        print('register gagal -> %s' % kode)
        return None
    kode, isi, _ = http('POST', '/api/auth/login', {'username': nama, 'password': 'rahasia123'})
    token = ((isi or {}).get('data') or {}).get('token') if kode == 200 else None
    if not token:
        print('login gagal -> %s' % kode)
    return token


def id_dari(isi):
    return ((isi or {}).get('data') or {}).get('id')


def uji_idempotensi(lap):
    print('== Idempotency-Key (poem-service, tabel idempotensi) ==')
    token = masuk()
    if not token:
        return lap.catat('idempotensi/login', False, 'tanpa token pengujian tidak bisa lanjut')
    kunci = str(uuid.uuid4())
    judul = 'Uji idempotensi ' + kunci[:8]

    k1, i1, h1 = http('POST', '/api/puisi', puisi(judul), token, {'Idempotency-Key': kunci})
    id1 = id_dari(i1)
    lap.catat('kiriman pertama', k1 == 202 and bool(id1) and 'idempotent-replay' not in h1,
              '202 diharapkan; kode=%s id=%s' % (k1, id1))

    k2, i2, h2 = http('POST', '/api/puisi', puisi(judul), token, {'Idempotency-Key': kunci})
    lap.catat('kiriman ulang sama', k2 == 202 and id_dari(i2) == id1 and h2.get('idempotent-replay') == 'true',
              'id sama dan Idempotent-Replay: true diharapkan; kode=%s id=%s replay=%s' % (k2, id_dari(i2), h2.get('idempotent-replay')))

    k3, _, _ = http('POST', '/api/puisi', puisi(judul + ' berbeda', 'Isi lain sama sekali.'), token, {'Idempotency-Key': kunci})
    lap.catat('kunci sama isi beda', k3 == 409, '409 diharapkan; kode=%s' % k3)

    k4, i4, h4 = http('POST', '/api/puisi', puisi(judul), token)
    lap.catat('tanpa kunci (kontrol)', k4 == 202 and id_dari(i4) not in (None, id1) and 'idempotent-replay' not in h4,
              'puisi baru (id berbeda) diharapkan; kode=%s id=%s' % (k4, id_dari(i4)))

    k5, _, _ = http('POST', '/api/puisi', puisi(judul), token, {'Idempotency-Key': 'pendek'})
    lap.catat('kunci tidak valid', k5 == 400, '400 diharapkan (kurang dari 8 karakter); kode=%s' % k5)
    return True


def uji_throttle(lap, jumlah=300, paralel=20):
    print('== Throttling gateway (429) ==')
    kode_get = {}
    for _ in range(120):
        k, _, _ = http('GET', '/api/puisi')
        kode_get[k] = kode_get.get(k, 0) + 1
    lap.catat('GET galeri tanpa 429', 429 not in kode_get and kode_get.get(0, 0) == 0,
              '120 GET -> %s' % json.dumps(kode_get, sort_keys=True))

    # POST tanpa token: gateway membatasi sebelum layanan memeriksa token, jadi tidak ada puisi yang dibuat.
    # Setiap gateway punya ember sendiri (5 per detik, burst 30), dan 3 gateway menerima lewat Swarm.
    def kirim(_):
        return http('POST', '/api/puisi', {'judul': 'x', 'isi': 'x'})

    with ThreadPoolExecutor(max_workers=paralel) as kolam:
        hasil = list(kolam.map(kirim, range(jumlah)))
    hitung = {}
    for k, _, _ in hasil:
        hitung[k] = hitung.get(k, 0) + 1
    contoh = next(((i, h) for k, i, h in hasil if k == 429), None)
    lap.catat('POST dibatasi (429)', hitung.get(429, 0) > 0,
              '%d POST cepat -> %s' % (jumlah, json.dumps(hitung, sort_keys=True)))
    lap.catat('429 berbentuk JSON', contoh is not None and (contoh[0] or {}).get('status') == 'error'
              and contoh[1].get('retry-after') == '1',
              'badan status=error dan Retry-After: 1 diharapkan; contoh=%s' % (json.dumps(contoh[0], ensure_ascii=False) if contoh else 'tidak ada 429'))
    lap.catat('selebihnya diteruskan', all(0 < k < 500 for k in hitung),
              'kode 5xx atau 0 berarti layanan di belakang gateway terganggu: %s' % json.dumps(hitung, sort_keys=True))
    time.sleep(6)   # ember terisi lagi (burst 30, isi ulang 5 per detik) supaya uji berikutnya tidak ikut kena 429


def pantau(detik, selang_tulis):
    """Satu GET per detik, satu POST berkunci tiap `selang_tulis` detik; kirim ulang bila 5xx atau putus (seperti web/js/kirim.js)."""
    token = masuk()
    if not token:
        return 1
    print('mulai %s, GATEWAY=%s, %d detik. Matikan server dengan Stop di konsol EC2 sambil ini berjalan.' % (time.strftime('%H:%M:%S'), GATEWAY, detik))
    awal, nomor = time.time(), 0
    jml = {'get': 0, 'get_gagal': 0, 'tulis': 0, 'tulis_gagal': 0, 'ulang': 0}
    while time.time() - awal < detik:
        mulai = time.time()
        k, _, _ = http('GET', '/api/puisi', batas=4)
        jml['get'] += 1
        if k != 200:
            jml['get_gagal'] += 1
        tulis = '-'
        if nomor % selang_tulis == 0:
            kunci, percobaan = str(uuid.uuid4()), 0
            while True:
                percobaan += 1
                kt, it, _ = http('POST', '/api/puisi', puisi('Uji pantau %s' % kunci[:8]), token, {'Idempotency-Key': kunci}, batas=8)
                if (kt >= 500 or kt == 0) and percobaan < 3:
                    jml['ulang'] += 1
                    time.sleep(0.5 * 2 ** (percobaan - 1))
                    continue
                break
            jml['tulis'] += 1
            if kt != 202:
                jml['tulis_gagal'] += 1
            tulis = '%s%s' % (kt, '' if percobaan == 1 else '(percobaan %d)' % percobaan)
        print('%s get=%s tulis=%s' % (time.strftime('%H:%M:%S'), k, tulis))
        sys.stdout.flush()
        nomor += 1
        time.sleep(max(0.0, 1.0 - (time.time() - mulai)))
    print('RINGKASAN: GET %(get)d (gagal %(get_gagal)d); tulis %(tulis)d (gagal %(tulis_gagal)d, dikirim ulang %(ulang)d kali)' % jml)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('perintah', choices=['idempotensi', 'throttle', 'semua', 'pantau'])
    ap.add_argument('--detik', type=int, default=600, help='lama pantau')
    ap.add_argument('--selang-tulis', type=int, default=5, help='pantau: satu POST tiap sekian detik (jaga di bawah batas 5 per detik)')
    a = ap.parse_args()
    if a.perintah == 'pantau':
        return pantau(a.detik, max(1, a.selang_tulis))
    lap = Laporan()
    if a.perintah in ('idempotensi', 'semua'):
        uji_idempotensi(lap)
    if a.perintah in ('throttle', 'semua'):
        uji_throttle(lap)
    return 0 if lap.ringkas() else 1


if __name__ == '__main__':
    sys.exit(main())
