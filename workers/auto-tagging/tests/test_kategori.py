import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import kategori  # noqa: E402
import praproses  # noqa: E402
import tagging  # noqa: E402


class TestLeksikon(unittest.TestCase):
    def test_kategori_tetap(self):
        self.assertEqual(set(kategori.KATEGORI),
                         {'cinta', 'alam', 'ketuhanan', 'perjuangan', 'kesedihan', 'sosial'})

    def test_setiap_kata_sudah_kata_dasar_dan_bukan_stopword(self):
        # kata yang berubah saat di-stem atau tersaring stopword tidak akan pernah cocok
        for k, kata in kategori.LEKSIKON.items():
            for w in kata:
                self.assertEqual(praproses.stemmer().stem(w), w, '%s di %s' % (w, k))
                self.assertNotIn(w, praproses.STOPWORD, '%s di %s' % (w, k))

    def test_satu_kata_satu_kategori(self):
        semua = [w for kata in kategori.LEKSIKON.values() for w in kata]
        self.assertEqual(len(semua), len(set(semua)))


class TestKategori(unittest.TestCase):
    def test_laut_dan_gunung_menjadi_alam(self):
        self.assertEqual(tagging.analisis('Pendakian', 'Dari puncak gunung aku memandang laut\n'
                                                       'gunung dan laut berbicara')['kategori'], 'alam')

    def test_tanpa_kata_leksikon_menjadi_umum(self):
        self.assertEqual(kategori.kategori(['meja', 'kursi', 'lemari']), 'umum')
        self.assertEqual(kategori.kategori([]), 'umum')

    def test_peringkat_atas_lebih_berat(self):
        # satu kata cinta di peringkat pertama mengalahkan dua kata alam di peringkat bawah
        self.assertEqual(kategori.kategori(['rindu', 'meja', 'kursi', 'laut', 'gunung']), 'cinta')

    def test_seri_diputus_urutan_kategori(self):
        # alam 3, cinta 2 + 1 = 3, cinta lebih dulu di KATEGORI
        self.assertEqual(kategori.kategori(['meja', 'kursi', 'laut', 'rindu', 'kasih']), 'cinta')

    def test_hanya_lima_kata_pertama_dihitung(self):
        self.assertEqual(kategori.kategori(['a', 'b', 'c', 'd', 'e', 'tuhan']), 'umum')


if __name__ == '__main__':
    unittest.main()
