#Uji pencarian dan visibilitas, pelengkap uji_e2e.py. Setiap tahap dilaporkan LULUS atau BELUM.

#python scripts/uji_pencarian.py
#python scripts/uji_pencarian.py --worker --tunggu 90

#uji_e2e.py hanya mencari kata "pinang", tidak memeriksa visibilitas, tag, atau genre. Script ini menyuntikkan event langsung ke RabbitMQ (seperti scripts/kirim_event.py) lalu memeriksa hasil /api/search lewat gateway. Hanya butuh profile pencarian, tanpa poem-service dan tanpa worker.

#Bila worker Auto-tagging atau Klasifikasi Genre sedang menyala, selalu pakai --worker. Worker ikut membaca puisi.dibuat uji dan menimpa tag dan genre yang disuntikkan, jadi tahap yang membandingkan nilai suntikan dilonggarkan: cukup tag dan genre ada, filternya tetap diuji.

import argparse
import json
import os
import random
import string
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kirim_event  
import rabbit

GATEWAY = os.environ.get('GATEWAY', 'http://localhost')


def json_atau_none(badan):
    try:
        return json.loads(badan) if badan else None
    except ValueError:
        return None


def cari(**param):
    """GET /api/search. Parameter _ membuat key Nginx berbeda tiap panggilan, server mengabaikannya,
    jadi yang diuji adalah Redis dan OpenSearch, bukan cache 10 detik di gateway."""
    param['_'] = repr(time.time())
    url = GATEWAY + '/api/search?' + urllib.parse.urlencode(param)
    try:
        with urllib.request.urlopen(url, timeout=10) as res:
            return res.status, json_atau_none(res.read()), res.headers.get('X-Cache-Layer')
    except urllib.error.HTTPError as e:
        return e.code, json_atau_none(e.read()), None
    except (urllib.error.URLError, OSError) as e:
        return 0, {'pesan': str(e)}, None


def hasil(**param):
    kode, isi, _ = cari(**param)
    return (isi or {}).get('data') or [] if kode == 200 else []


def ada(id_puisi, **param):
    return any(h.get('id') == id_puisi for h in hasil(**param))


def tunggu(kondisi, detik):
    batas = time.time() + detik
    while time.time() < batas:
        if kondisi():
            return True
        time.sleep(1)
    return kondisi()


def kirim(tipe, data):
    event = kirim_event.amplop(tipe, data, None)
    jawab = rabbit.panggil('POST', '/exchanges/%s/puisi.events/publish' % rabbit.VHOST, {
        'routing_key': tipe,
        'payload': json.dumps(event, ensure_ascii=False),
        'payload_encoding': 'string',
        'properties': {'content_type': 'application/json', 'delivery_mode': 2,
                       'correlation_id': event['correlation_id']},
    })
    if not jawab.get('routed'):
        raise SystemExit('event %s tidak diteruskan ke queue manapun. Sudah docker compose up?' % tipe)


def dibuat(id_puisi, kata, visibilitas='publik', **tambahan):
    data = {'puisi_id': id_puisi, 'judul': 'Uji %s' % kata,
            'isi': 'baris pertama %s\nbaris kedua penguji' % kata,
            'penulis': 'Penguji', 'kategori': None, 'keyword': None}
    if visibilitas is not None:
        data['visibilitas'] = visibilitas
    data.update(tambahan)
    kirim('puisi.dibuat', data)


def analisis(id_puisi, sumber, hasil_worker):
    kirim('puisi.dianalisis', {'puisi_id': id_puisi, 'sumber': sumber, 'hasil': hasil_worker})


def tag_genre(id_puisi, tag, genre='pantun'):
    analisis(id_puisi, 'auto-tagging', {'keyword': [tag, 'penguji'], 'kategori': 'uji'})
    analisis(id_puisi, 'klasifikasi-genre', {'genre': genre, 'skema_rima': 'abab'})


def puisi_lengkap(id_puisi, kata, tag_suntikan, genre_suntikan, ketat):
    h = next((x for x in hasil(q=kata) if x.get('id') == id_puisi), None)
    if not h or not h.get('tag') or not h.get('genre'):
        return False
    if ketat and (tag_suntikan not in h['tag'] or h['genre'] != genre_suntikan):
        return False
    return ada(id_puisi, tag=h['tag'][0], genre=h['genre'])


class Laporan(object):
    def __init__(self):
        self.baris = []

    def catat(self, tahap, lulus, ket):
        self.baris.append((tahap, lulus))
        print('%-18s %-6s %s' % (tahap, 'LULUS' if lulus else 'BELUM', ket))
        return lulus


def acak(n):
    return ''.join(random.choice(string.ascii_lowercase) for _ in range(n))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tunggu', type=int, default=30, help='batas tunggu tiap tahap, detik')
    ap.add_argument('--worker', action='store_true', help='uji juga tag dan genre dari worker sungguhan')
    a = ap.parse_args()
    lap = Laporan()

    kode, isi, _ = cari(q='pinang')
    if not lap.catat('layanan', kode == 200, 'GET /api/search -> %s' % (kode or (isi or {}).get('pesan'))):
        print('-- search-service belum berjalan: docker compose --profile pencarian up -d')
        return 1

    kata = 'uji' + acak(10)
    tag = 'tag' + acak(10)
    dasar = random.randint(900000, 990000)
    pub, privat_id, tanpa, sentinel, terbalik, ubah, sentinel2, sentinel3 = (dasar + i for i in range(8))
    semua = [pub, privat_id, tanpa, sentinel, terbalik, ubah, sentinel2, sentinel3]
    kata_penghalang = 'uji' + acak(10) 
    t = a.tunggu
    ketat = not a.worker  #tanpa worker, tag dan genre suntikan tidak ditimpa siapa pun

    #1. puisi publik dengan tag dan genre dari event analisis
    dibuat(pub, kata)
    tag_genre(pub, tag)
    ok = tunggu(lambda: ada(pub, q=kata), t)
    lap.catat('publik-kata', ok, 'q=%s menemukan puisi publik' % kata)
    ok = tunggu(lambda: puisi_lengkap(pub, kata, tag, 'pantun', ketat), t)
    lap.catat('publik-tag-genre', ok, 'filter tag dan genre menemukan puisi yang sama')

    #2. puisi privat dan tanpa tanda dikirim lebih dulu, sentinel publik sesudahnya. Satu consumer memproses berurutan, jadi saat sentinel sudah ditemukan, keduanya pasti sudah diproses
    dibuat(privat_id, kata, 'privat')
    tag_genre(privat_id, tag)
    dibuat(tanpa, kata, None)
    tag_genre(tanpa, tag)
    dibuat(sentinel, kata)
    diproses = tunggu(lambda: ada(sentinel, q=kata), t)
    lap.catat('penghalang', diproses, 'event privat dan tanpa tanda sudah diproses (sentinel ditemukan)')
    pencarian = {
        'kata': dict(q=kata),
        'tag': dict(tag=tag),
        'tag+genre': dict(tag=tag, genre='pantun'),
        'kata+tag': dict(q=kata, tag=tag),
    }
    bocor = [n for n, p in pencarian.items() if ada(privat_id, **p)]
    lap.catat('privat-tersembunyi', diproses and not bocor,
              'tidak muncul lewat kata, tag, genre' if not bocor else 'BOCOR lewat: %s' % ', '.join(bocor))
    bocor = [n for n, p in pencarian.items() if ada(tanpa, **p)]
    lap.catat('tanpa-tanda', diproses and not bocor,
              'puisi tanpa visibilitas tidak muncul' if not bocor else 'BOCOR lewat: %s' % ', '.join(bocor))

    #3. hasil analisis datang sebelum puisinya: tersembunyi dulu, lengkap setelah puisi tiba
    tag2 = 'tag' + acak(10)
    tag_genre(terbalik, tag2, 'syair')
    dibuat(sentinel2, kata_penghalang)  
    tunggu(lambda: ada(sentinel2, q=kata_penghalang), t)
    sebelum = ada(terbalik, tag=tag2)
    dibuat(terbalik, kata)
    ok = tunggu(lambda: puisi_lengkap(terbalik, kata, tag2, 'syair', ketat), t)
    lap.catat('urutan-terbalik', ok and not sebelum,
              'tersembunyi sebelum puisi tiba, lengkap sesudahnya' if ok and not sebelum
              else 'sebelum=%s, sesudah=%s' % (sebelum, ok))

    #4. puisi publik yang sudah ada di cache diubah menjadi privat: harus hilang seketika
    dibuat(ubah, kata)
    tag_genre(ubah, tag)
    tunggu(lambda: ada(ubah, q=kata), t)
    lapis = [cari(q=kata)[2] for _ in range(2)]
    dibuat(ubah, kata, 'privat')
    hilang = tunggu(lambda: not ada(ubah, q=kata), t)
    ulang = [ada(ubah, q=kata) for _ in range(3)]
    lap.catat('jadi-privat', hilang and not any(ulang),
              'hilang dari pencarian, tiga panggilan berikutnya juga (lapis sebelumnya: %s)' % '/'.join(str(x) for x in lapis))

    #5. event yang sama dua kali tidak menggandakan hasil
    sebelum_n = (cari(q=kata)[1] or {}).get('total')
    dibuat(pub, kata)
    dibuat(pub, kata)
    dibuat(sentinel3, kata_penghalang)
    tunggu(lambda: ada(sentinel3, q=kata_penghalang), t)
    sesudah_n = (cari(q=kata)[1] or {}).get('total')
    lap.catat('event-ganda', sebelum_n == sesudah_n and sebelum_n is not None,
              'total q=%s tetap %s' % (kata, sesudah_n))

    #6. parameter buruk ditolak, karakter aneh tidak membuat error
    k1, _, _ = cari(hal='-1')
    k2, _, _ = cari(q='"/\\ AND OR :[]{}')
    lap.catat('parameter', k1 == 400 and k2 == 200, 'hal=-1 -> %s, q berisi tanda kutip dan garis miring -> %s' % (k1, k2))

    #7. opsional: tag dan genre dari worker sungguhan
    if a.worker:
        w = dasar + 10
        kata_w = 'uji' + acak(10)
        data = {'puisi_id': w, 'judul': 'Pagi di Ladang %s' % kata_w,
                'isi': ('Pergi ke pasar membeli padi,\nPulang ke rumah membawa pinang,\n'
                        'Jika engkau berbaik hati,\nHidup bersama terasa tenang.\n%s' % kata_w),
                'penulis': 'Penguji', 'kategori': None, 'keyword': None, 'visibilitas': 'publik'}
        kirim('puisi.dibuat', data)
        semua.append(w)

        def lengkap():
            h = [x for x in hasil(q=kata_w) if x.get('id') == w]
            return h[0] if h and h[0].get('tag') and h[0].get('genre') else None

        tunggu(lambda: lengkap() is not None, max(t, 60))
        h = lengkap()
        if h:
            ok = ada(w, tag=h['tag'][0], genre=h['genre'])
            lap.catat('worker-tag-genre', ok, 'worker menghasilkan tag=%s genre=%s, pencarian dengan nilai itu %s'
                      % (h['tag'][0], h['genre'], 'menemukannya' if ok else 'TIDAK menemukannya'))
        else:
            lap.catat('worker-tag-genre', False, 'tag dan genre dari worker belum masuk indeks. Profile auto-tagging dan genre menyala?')

    for i in semua:
        dibuat(i, kata, 'privat')
    sisa = tunggu(lambda: not hasil(q=kata) and not hasil(q=kata_penghalang), t)
    lap.catat('bersih', sisa, 'puisi uji disembunyikan dari pencarian')

    lulus = sum(1 for _, l in lap.baris if l)
    print('-- %d dari %d tahap LULUS' % (lulus, len(lap.baris)))
    return 0 if lulus == len(lap.baris) else 1


if __name__ == '__main__':
    raise SystemExit(main())
