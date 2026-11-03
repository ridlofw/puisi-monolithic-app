"""JWT HS256 sesuai kontrak, untuk menguji layanan yang butuh login tanpa auth-service.

    python scripts/token_uji.py                         token untuk pengguna uji, berlaku 60 menit
    python scripts/token_uji.py --sub 2 --nama "Ayu"    pengguna lain
    python scripts/token_uji.py --periksa-vektor        cocokkan implementasi ini dengan kontrak/jwt-vektor.json

Kunci dibaca dari secrets/jwt_secret.txt, buat dulu dengan scripts/siapkan_rahasia.py.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time

AKAR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HEADER = {'alg': 'HS256', 'typ': 'JWT'}
URUTAN_KLAIM = ('sub', 'username', 'nama', 'iat', 'exp')


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b'=').decode('ascii')


def kompak(obj):
    return json.dumps(obj, separators=(',', ':')).encode('utf-8')


def buat_token(klaim, kunci):
    urut = {k: klaim[k] for k in URUTAN_KLAIM}
    kepala = b64url(kompak(HEADER)) + '.' + b64url(kompak(urut))
    tanda = hmac.new(kunci.encode('utf-8'), kepala.encode('ascii'), hashlib.sha256).digest()
    return kepala + '.' + b64url(tanda)


def periksa_vektor():
    with open(os.path.join(AKAR, 'kontrak', 'jwt-vektor.json'), encoding='utf-8') as f:
        v = json.load(f)
    ok = buat_token(v['klaim'], v['kunci']) == v['token_benar']
    ok_lama = buat_token(v['klaim_kedaluwarsa'], v['kunci']) == v['token_kedaluwarsa']
    ok_salah = buat_token(v['klaim'], v['kunci']) != v['token_tanda_tangan_salah']
    for nama, hasil in (('token benar', ok), ('token kedaluwarsa', ok_lama),
                        ('tanda tangan salah berbeda', ok_salah)):
        print('%-28s %s' % (nama, 'cocok' if hasil else 'TIDAK COCOK'))
    return ok and ok_lama and ok_salah


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sub', default='1')
    ap.add_argument('--username', default='penyair')
    ap.add_argument('--nama', default='Penyair Uji')
    ap.add_argument('--menit', type=int, default=60)
    ap.add_argument('--periksa-vektor', action='store_true')
    a = ap.parse_args()

    if a.periksa_vektor:
        sys.exit(0 if periksa_vektor() else 1)

    path = os.path.join(AKAR, 'secrets', 'jwt_secret.txt')
    if not os.path.exists(path):
        sys.exit('secrets/jwt_secret.txt belum ada. Jalankan python scripts/siapkan_rahasia.py')
    with open(path, encoding='utf-8') as f:
        kunci = f.read().strip()
    sekarang = int(time.time())
    print(buat_token({'sub': str(a.sub), 'username': a.username, 'nama': a.nama,
                      'iat': sekarang, 'exp': sekarang + a.menit * 60}, kunci))


if __name__ == '__main__':
    main()
