"""Praproses ringan teks puisi bahasa Indonesia.

Praproses mencakup:
- Pembersihan karakter non-alfanumerik dan huruf kecil.
- Pemisahan bait (berdasarkan baris kosong) dan pemisahan baris.
- Tokenisasi kata.
- Stemming PySastrawi bertahap: hanya dipanggil bila kata asli tidak ada di leksikon.
"""
import re

_STEMMER = None


def dapatkan_stemmer():
    global _STEMMER
    if _STEMMER is None:
        try:
            from Sastrawi.Stemmer.StemmerFactory import StemmerFactory
            factory = StemmerFactory()
            _STEMMER = factory.create_stemmer()
        except ImportError:
            # Fallback jika PySastrawi belum terpasang
            class StemmerPalsu(object):
                def stem(self, teks):
                    return teks
            _STEMMER = StemmerPalsu()
    return _STEMMER


def bersihkan_dan_tokenisasi(baris):
    """Bersihkan baris puisi dan kembalikan daftar kata dalam huruf kecil."""
    baris = baris.lower()
    # Hapus karakter non alfanumerik kecuali spasi dan tanda hubung
    baris = re.sub(r'[^a-z0-9\s\-]', ' ', baris)
    kata_kata = [k.strip() for k in baris.split() if k.strip()]
    return kata_kata


def pisah_bait(teks):
    """Pecah teks puisi menjadi daftar bait.

    Setiap bait adalah daftar baris-baris puisi.
    Bait dipisahkan oleh satu atau lebih baris kosong.
    """
    if not teks or not teks.strip():
        return []
    blok_bait = re.split(r'\n\s*\n', teks.strip())
    daftar_bait = []
    for blok in blok_bait:
        baris_baris = [b.strip() for b in blok.split('\n') if b.strip()]
        if baris_baris:
            daftar_bait.append(baris_baris)
    return daftar_bait
