import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import praproses  # noqa: E402


class TestPraproses(unittest.TestCase):
    def test_stopword_hilang(self):
        hasil = praproses.token('aku dan engkau yang di sana')
        self.assertEqual(hasil, [])

    def test_stopword_sesudah_stemming_juga_hilang(self):
        # bersama baru menjadi stopword sama setelah di-stem
        self.assertNotIn('sama', praproses.token('hidup bersama'))

    def test_kata_ulang_di_stem_utuh(self):
        self.assertEqual(praproses.token('berlari-lari'), ['lari'])

    def test_imbuhan_di_stem(self):
        self.assertEqual(praproses.token('pepohonan perjuangan kesedihan'), ['pohon', 'juang', 'sedih'])

    def test_tanda_baca_dan_angka_hilang(self):
        self.assertEqual(praproses.token('Gunung, 1945! laut... (2026)'), ['gunung', 'laut'])

    def test_huruf_besar_disamakan(self):
        self.assertEqual(praproses.token('SAMUDRA Samudra samudra'), ['samudra'] * 3)

    def test_teks_kosong(self):
        self.assertEqual(praproses.token(''), [])
        self.assertEqual(praproses.token('   \n\n  '), [])
        self.assertEqual(praproses.token(None), [])

    def test_urutan_kemunculan_dipertahankan(self):
        self.assertEqual(praproses.token('laut gunung laut'), ['laut', 'gunung', 'laut'])


if __name__ == '__main__':
    unittest.main()
