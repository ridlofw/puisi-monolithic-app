"""Hasil empat puisi contoh di kontrak/contoh/, ditetapkan manual setelah diperiksa.

Bila korpus, leksikon, atau praproses diubah dan tes ini gagal, periksa hasil barunya lalu
perbarui harapan di sini dan contoh di kontrak/contoh/dianalisis.auto-tagging.json.
"""
import json
import os
import sys
import unittest

AKAR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, AKAR)

import bangun_df  # noqa: E402
import tagging  # noqa: E402

CONTOH = os.path.join(AKAR, '..', '..', 'kontrak', 'contoh')

HARAPAN = {
    'pantun': (['ladang', 'pergi', 'beli', 'padi', 'pinang'], 'alam'),
    'syair': (['tani', 'syair', 'kisah', 'padi', 'panas'], 'sosial'),
    'gurindam': (['lisan', 'gurindam', 'jaga', 'hindar', 'susah'], 'umum'),
    'bebas': (['tua', 'kota', 'basuh', 'lupa', 'turun'], 'umum'),
}


def muat(nama):
    with open(os.path.join(CONTOH, nama + '.json'), encoding='utf-8') as f:
        return json.load(f)


class TestRegresi(unittest.TestCase):
    def test_empat_puisi_contoh(self):
        for nama, (keyword, kat) in HARAPAN.items():
            d = muat(nama)
            with self.subTest(puisi=nama):
                self.assertEqual(tagging.analisis(d['judul'], d['isi']),
                                 {'keyword': keyword, 'kategori': kat})

    def test_contoh_hasil_di_kontrak_sama_dengan_keluaran(self):
        d = muat('dianalisis.auto-tagging')
        pantun = muat('pantun')
        self.assertEqual(d['puisi_id'], pantun['puisi_id'])
        self.assertEqual(d['sumber'], 'auto-tagging')
        self.assertEqual(d['hasil'], tagging.analisis(pantun['judul'], pantun['isi']))

    def test_df_json_sesuai_korpus(self):
        # df.json yang di-commit harus sama dengan hasil bangun_df.py dari korpus sekarang
        with open(bangun_df.BERKAS_KORPUS, encoding='utf-8') as f:
            baru = bangun_df.ke_teks(bangun_df.bangun(f.read()))
        with open(bangun_df.BERKAS_DF, encoding='utf-8') as f:
            self.assertEqual(f.read(), baru, 'df.json usang, jalankan python bangun_df.py')


if __name__ == '__main__':
    unittest.main()
