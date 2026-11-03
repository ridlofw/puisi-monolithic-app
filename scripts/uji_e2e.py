"""Uji ujung ke ujung lewat gateway. Setiap tahap dilaporkan LULUS atau BELUM.

    python scripts/uji_e2e.py
    python scripts/uji_e2e.py --tunggu 90

Boleh dijalankan kapan saja selama pengembangan. Tahap yang layanannya belum
di-merge atau belum dijalankan muncul sebagai BELUM, bukan error.
"""
import argparse
import json
import os
import time
import urllib.error
import urllib.request
import uuid

GATEWAY = os.environ.get('GATEWAY', 'http://localhost')

PUISI = {
    'judul': 'Pagi di Ladang',
    'isi': 'Pergi ke pasar membeli padi,\nPulang ke rumah membawa pinang,\n'
           'Jika engkau berbaik hati,\nHidup bersama terasa tenang.',
    'tgl_submit': time.strftime('%Y-%m-%d'),
    'kategori': '',
    'keyword': '',
}


def json_atau_none(badan):
    try:
        return json.loads(badan) if badan else None
    except ValueError:
        return None


def http(metode, path, isi=None, token=None):
    data = json.dumps(isi).encode('utf-8') if isi is not None else None
    req = urllib.request.Request(GATEWAY + path, data=data, method=metode)
    req.add_header('Content-Type', 'application/json')
    if token:
        req.add_header('Authorization', 'Bearer ' + token)
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return res.status, json_atau_none(res.read())
    except urllib.error.HTTPError as e:
        return e.code, json_atau_none(e.read())
    except (urllib.error.URLError, OSError) as e:
        return 0, {'pesan': str(e)}


class Laporan(object):
    def __init__(self):
        self.baris = []

    def catat(self, tahap, lulus, ket):
        self.baris.append((tahap, lulus))
        print('%-10s %-6s %s' % (tahap, 'LULUS' if lulus else 'BELUM', ket))
        return lulus


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tunggu', type=int, default=60, help='batas tunggu hasil asinkron, detik')
    a = ap.parse_args()
    lap = Laporan()

    kode, _ = http('GET', '/')
    lap.catat('gateway', kode == 200, 'GET / -> %s' % (kode or 'tidak terjangkau'))

    nama = 'e2e' + uuid.uuid4().hex[:8]
    kode, isi = http('POST', '/api/auth/register',
                     {'username': nama, 'password': 'rahasia123', 'nama': 'Penyair E2E', 'no_id': '0'})
    lap.catat('register', kode in (200, 201), 'POST /api/auth/register -> %s' % kode)

    kode, isi = http('POST', '/api/auth/login', {'username': nama, 'password': 'rahasia123'})
    token = ((isi or {}).get('data') or {}).get('token') if kode == 200 else None
    lap.catat('login', bool(token), 'POST /api/auth/login -> %s' % kode)

    id_puisi = None
    if token:
        kode, isi = http('POST', '/api/puisi', PUISI, token)
        id_puisi = ((isi or {}).get('data') or {}).get('id') if kode == 202 else None
        lap.catat('submit', bool(id_puisi), 'POST /api/puisi -> %s' % kode)
    else:
        lap.catat('submit', False, 'butuh token dari tahap login')

    detail = None
    if id_puisi:
        kode, isi = http('GET', '/api/puisi/%s' % id_puisi)
        detail = (isi or {}).get('data') if kode == 200 else None
        lap.catat('detail', bool(detail), 'GET /api/puisi/%s -> %s' % (id_puisi, kode))
    else:
        lap.catat('detail', False, 'butuh id dari tahap submit')

    tunggu = {'tag': 'auto-tagging', 'genre': 'klasifikasi-genre', 'emosi': 'analisis-emosi'}
    selesai, url_audio = {}, None
    if detail:
        batas = time.time() + a.tunggu
        while time.time() < batas:
            kode, isi = http('GET', '/api/puisi/%s' % id_puisi)
            d = (isi or {}).get('data') or {}
            analisis = d.get('analisis') or {}
            for tahap, sumber in tunggu.items():
                if sumber in analisis:
                    selesai[tahap] = analisis[sumber]
            url_audio = d.get('url_audio') or url_audio
            if len(selesai) == len(tunggu) and url_audio:
                break
            time.sleep(2)
    for tahap, sumber in tunggu.items():
        if tahap in selesai:
            lap.catat(tahap, True, json.dumps(selesai[tahap], ensure_ascii=False)[:80])
        else:
            lap.catat(tahap, False, 'analisis.%s belum ada' % sumber if detail else 'butuh detail puisi')
    if url_audio:
        kode, _ = http('GET', url_audio)
        lap.catat('audio', kode == 200, 'GET %s -> %s' % (url_audio, kode))
    else:
        lap.catat('audio', False, 'url_audio belum ada' if detail else 'butuh detail puisi')

    kode, isi = http('GET', '/api/search?q=pinang')
    hasil = (isi or {}).get('data') or []
    ketemu = any(str(h.get('id')) == str(id_puisi) for h in hasil) if id_puisi else bool(hasil)
    lap.catat('pencarian', kode == 200 and ketemu, 'GET /api/search?q=pinang -> %s, %d hasil' % (kode, len(hasil)))

    lulus = sum(1 for _, l in lap.baris if l)
    print('-- %d dari %d tahap LULUS' % (lulus, len(lap.baris)))
    return 0 if lulus == len(lap.baris) else 1


if __name__ == '__main__':
    raise SystemExit(main())
