"""Aturan klasifikasi bentuk puisi dari jumlah baris dan skema rima per bait.

Tanpa ketergantungan luar: hanya memakai pustaka standar Python.
"""
import re

VOKAL = 'aiueo'


def pisah_bait(isi):
    """Pisahkan teks puisi menjadi daftar bait (tiap bait berupa daftar baris).

    Bait dipisahkan oleh satu atau lebih baris kosong. Spasi di ujung baris
    dan baris kosong di awal/akhir teks diabaikan.
    """
    if not isinstance(isi, str) or not isi.strip():
        return []
    teks = isi.replace('\r\n', '\n').replace('\r', '\n').strip()
    daftar_bait = []
    for blok in re.split(r'\n\s*\n+', teks):
        baris = [b.strip() for b in blok.split('\n') if b.strip()]
        if baris:
            daftar_bait.append(baris)
    return daftar_bait


def bunyi_akhir(baris):
    """Ambil bunyi akhir sebuah baris: vokal terakhir beserta konsonan sesudahnya.

    Tanda baca dan angka diabaikan, huruf dijadikan kecil. Contoh:
    'membeli padi,' -> 'i', 'membawa pinang.' -> 'ang', 'jalan' -> 'an'.
    """
    if not isinstance(baris, str):
        return ''
    kata = re.findall(r'[a-z]+', baris.lower())
    if not kata:
        return ''
    terakhir = kata[-1]
    for i in range(len(terakhir) - 1, -1, -1):
        if terakhir[i] in VOKAL:
            return terakhir[i:]
    return terakhir


def skema_bait(daftar_baris):
    """Bentuk skema rima satu bait (misalnya 'abab', 'aaaa', 'aa')."""
    peta = {}
    huruf_berikut = ord('a')
    hasil = []
    for baris in daftar_baris:
        bunyi = bunyi_akhir(baris)
        if not bunyi:
            # Baris tanpa kata alfabet tidak boleh dianggap berima dengan baris lain
            hasil.append('?')
            continue
        if bunyi not in peta:
            peta[bunyi] = chr(huruf_berikut)
            huruf_berikut += 1
        hasil.append(peta[bunyi])
    return ''.join(hasil)


def klasifikasi(isi):
    """Tentukan genre dan skema rima dari isi puisi.

    Aturan:
    - semua bait 4 baris dengan rima abab -> pantun
    - semua bait 4 baris dengan rima aaaa -> syair
    - semua bait 2 baris dengan rima aa   -> gurindam
    - selain itu                          -> puisi bebas
    """
    semua_bait = pisah_bait(isi)
    if not semua_bait:
        return {'genre': 'puisi bebas', 'skema_rima': ''}

    daftar_skema = [skema_bait(bait) for bait in semua_bait]
    if all(len(b) == 4 and s == 'abab' for b, s in zip(semua_bait, daftar_skema)):
        genre = 'pantun'
    elif all(len(b) == 4 and s == 'aaaa' for b, s in zip(semua_bait, daftar_skema)):
        genre = 'syair'
    elif all(len(b) == 2 and s == 'aa' for b, s in zip(semua_bait, daftar_skema)):
        genre = 'gurindam'
    else:
        genre = 'puisi bebas'

    return {
        'genre': genre,
        'skema_rima': ' '.join(daftar_skema),
    }

