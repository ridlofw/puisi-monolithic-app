"""Praproses teks puisi menjadi daftar kata dasar.

Urutannya: huruf kecil, buang tanda baca dan angka, tokenisasi, buang stopword, stemming
Sastrawi, lalu buang stopword sekali lagi karena kata seperti bersama baru menjadi stopword
setelah di-stem.
"""
import re

from Sastrawi.Stemmer.StemmerFactory import StemmerFactory
from Sastrawi.StopWordRemover.StopWordRemoverFactory import StopWordRemoverFactory

PANJANG_MIN = 3
# tanda hubung dipertahankan di dalam kata agar kata ulang seperti berlari-lari di-stem utuh
_KATA = re.compile(r'[a-z]+(?:-[a-z]+)*')

# kata ganti dan kata seru puisi, serta frasa baku seperti barang siapa dan sepenuh hati,
# yang tidak ada di daftar Sastrawi
STOPWORD_PUISI = frozenset({
    'engkau', 'kau', 'dikau', 'daku', 'beta', 'adinda', 'kanda', 'tuan', 'puan',
    'duhai', 'gerangan', 'nan', 'jua', 'barang', 'sepenuh',
})

_stemmer = None
STOPWORD = frozenset(StopWordRemoverFactory().get_stop_words()) | STOPWORD_PUISI


def stemmer():
    # kamus Sastrawi dimuat sekali per proses, pemuatan pertama sekitar satu detik
    global _stemmer
    if _stemmer is None:
        _stemmer = StemmerFactory().create_stemmer()
    return _stemmer


def token(teks):
    hasil = []
    for kata in _KATA.findall((teks or '').lower()):
        if kata in STOPWORD:
            continue
        dasar = stemmer().stem(kata)
        if len(dasar) < PANJANG_MIN or dasar in STOPWORD:
            continue
        hasil.append(dasar)
    return hasil
