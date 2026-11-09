import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import tfidf  # noqa: E402

KORPUS = tfidf.Korpus(10, {'malam': 9, 'hati': 8, 'laut': 2, 'gunung': 1})


class TestIdf(unittest.TestCase):
    def test_kata_jarang_lebih_berat(self):
        self.assertGreater(KORPUS.idf('gunung'), KORPUS.idf('malam'))

    def test_kata_di_luar_korpus_mendapat_idf_maksimum(self):
        semua = [KORPUS.idf(k) for k in KORPUS.df]
        self.assertGreater(KORPUS.idf('pelangi'), max(semua))

    def test_df_json_dapat_dimuat(self):
        k = tfidf.Korpus.muat()
        self.assertGreater(k.n_dokumen, 0)
        self.assertTrue(k.df)


class TestKataKunci(unittest.TestCase):
    def test_sering_di_puisi_jarang_di_korpus_naik_ke_atas(self):
        tokens = ['malam', 'malam', 'hati', 'gunung', 'gunung', 'laut']
        self.assertEqual(tfidf.kata_kunci(tokens, KORPUS)[0], 'gunung')

    def test_kata_umum_kalah_walau_sama_sering(self):
        hasil = tfidf.kata_kunci(['malam', 'laut'], KORPUS)
        self.assertEqual(hasil, ['laut', 'malam'])

    def test_paling_banyak_lima_tanpa_duplikat(self):
        tokens = ['a%d' % i for i in range(12)] * 2
        hasil = tfidf.kata_kunci(tokens, KORPUS)
        self.assertEqual(len(hasil), 5)
        self.assertEqual(len(set(hasil)), 5)

    def test_kurang_dari_lima_kata(self):
        self.assertEqual(tfidf.kata_kunci(['laut'], KORPUS), ['laut'])

    def test_deterministik(self):
        tokens = ['senja', 'pantai', 'ombak', 'camar', 'pasir', 'karang', 'jingga']
        self.assertEqual(tfidf.kata_kunci(tokens, KORPUS), tfidf.kata_kunci(list(tokens), KORPUS))

    def test_skor_seri_diputus_kemunculan_pertama(self):
        tokens = ['senja', 'pantai', 'ombak', 'camar', 'pasir', 'karang', 'jingga']
        self.assertEqual(tfidf.kata_kunci(tokens, KORPUS), tokens[:5])

    def test_tanpa_token(self):
        self.assertEqual(tfidf.kata_kunci([], KORPUS), [])


if __name__ == '__main__':
    unittest.main()
