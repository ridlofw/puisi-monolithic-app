"""Bangun df.json dari korpus/puisi.txt. Jalankan ulang setiap kali korpus diubah.

    python bangun_df.py

Puisi di korpus dipisah oleh baris berisi --- saja. df setiap kata adalah jumlah puisi
yang memuat kata dasar itu setelah praproses.
"""
import json
import os
import re

import praproses
from tfidf import BERKAS_DF

BERKAS_KORPUS = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'korpus', 'puisi.txt')
_PEMISAH = re.compile(r'^---\s*$', re.MULTILINE)


def pecah(teks):
    return [p.strip() for p in _PEMISAH.split(teks) if p.strip()]


def bangun(teks):
    puisi = pecah(teks)
    df = {}
    for p in puisi:
        for kata in set(praproses.token(p)):
            df[kata] = df.get(kata, 0) + 1
    return {'n_dokumen': len(puisi), 'df': dict(sorted(df.items()))}


def ke_teks(isi):
    return json.dumps(isi, ensure_ascii=False, indent=1, sort_keys=True) + '\n'


def main():
    with open(BERKAS_KORPUS, encoding='utf-8') as f:
        isi = bangun(f.read())
    with open(BERKAS_DF, 'w', encoding='utf-8', newline='\n') as f:
        f.write(ke_teks(isi))
    print('%d puisi, %d kata dasar, ditulis ke %s' % (isi['n_dokumen'], len(isi['df']), BERKAS_DF))


if __name__ == '__main__':
    main()
