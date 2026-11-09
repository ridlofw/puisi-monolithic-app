"""Kata kunci dengan TF-IDF terhadap korpus rujukan yang dibundel.

df.json dibangun sekali oleh bangun_df.py dan tidak berubah selama worker berjalan, jadi
worker tetap stateless dan puisi yang sama selalu menghasilkan kata kunci yang sama.
"""
import json
import math
import os
from collections import Counter

JUMLAH_KATA = 5
BERKAS_DF = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'df.json')


class Korpus(object):
    def __init__(self, n_dokumen, df):
        self.n_dokumen = n_dokumen
        self.df = df

    @classmethod
    def muat(cls, path=BERKAS_DF):
        with open(path, encoding='utf-8') as f:
            isi = json.load(f)
        return cls(isi['n_dokumen'], isi['df'])

    def idf(self, kata):
        # idf halus, kata di luar korpus punya df 0 sehingga mendapat idf maksimum
        return math.log((1 + self.n_dokumen) / (1 + self.df.get(kata, 0))) + 1


def kata_kunci(tokens, korpus, jumlah=JUMLAH_KATA):
    if not tokens:
        return []
    tf = Counter(tokens)
    total = len(tokens)
    skor = {k: (n / total) * korpus.idf(k) for k, n in tf.items()}
    pertama = {}
    for i, k in enumerate(tokens):
        pertama.setdefault(k, i)
    # skor sama diputus oleh kemunculan pertama, jadi kata dari judul didahulukan
    urut = sorted(skor, key=lambda k: (-round(skor[k], 9), pertama[k]))
    return urut[:jumlah]
