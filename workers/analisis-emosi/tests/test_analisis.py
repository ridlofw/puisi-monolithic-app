"""Unit test untuk modul analisis sentimen dan emosi puisi Indonesia."""
import os
import sys
import unittest

DIR_TESTS = os.path.dirname(os.path.abspath(__file__))
DIR_WORKER = os.path.dirname(DIR_TESTS)
sys.path.insert(0, DIR_WORKER)

from analisis import MesinAnalisis  # noqa: E402
from praproses import bersihkan_dan_tokenisasi, pisah_bait  # noqa: E402


class TestPraproses(unittest.TestCase):
    def test_tokenisasi_membersihkan_tanda_baca(self):
        kata = bersihkan_dan_tokenisasi("Hai, dunia! Ini adalah... Puisi?")
        self.assertEqual(kata, ["hai", "dunia", "ini", "adalah", "puisi"])

    def test_pisah_bait(self):
        teks = "Bait satu baris satu\nBait satu baris dua\n\nBait dua baris satu\nBait dua baris dua"
        bait = pisah_bait(teks)
        self.assertEqual(len(bait), 2)
        self.assertEqual(len(bait[0]), 2)
        self.assertEqual(len(bait[1]), 2)

    def test_teks_kosong_menghasilkan_daftar_kosong(self):
        self.assertEqual(pisah_bait(""), [])
        self.assertEqual(bersihkan_dan_tokenisasi(""), [])


class TestAnalisisSentimenDanEmosi(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mesin = MesinAnalisis()

    def test_baris_jelas_positif(self):
        skor, label, _ = self.mesin.analisis_baris("Hari ini sangat indah, penuh cinta dan bahagia.")
        self.assertEqual(label, "positif")
        self.assertGreater(skor, 0.05)

    def test_baris_jelas_negatif(self):
        skor, label, _ = self.mesin.analisis_baris("Hatiku hancur dalam duka dan derita yang pedih.")
        self.assertEqual(label, "negatif")
        self.assertLess(skor, -0.05)

    def test_negasi_tidak_bahagia_menjadi_negatif(self):
        skor, label, _ = self.mesin.analisis_baris("Aku tidak bahagia")
        self.assertEqual(label, "negatif")
        self.assertLess(skor, -0.05)

    def test_baris_tanpa_kata_leksikon_menjadi_netral_bukan_error(self):
        skor, label, emosi = self.mesin.analisis_baris("xyz abc klm nop qrs tuv")
        self.assertEqual(skor, 0.0)
        self.assertEqual(label, "netral")
        self.assertEqual(emosi, [])

    def test_emosi_dominan_pantun_contoh(self):
        # Puisi 1: Pantun Pagi di Ladang
        isi_pantun = (
            "Pergi ke pasar membeli padi,\n"
            "Pulang ke rumah membawa pinang,\n"
            "Jika engkau berbaik hati,\n"
            "Hidup bersama terasa tenang."
        )
        hasil = self.mesin.analisis_puisi(isi_pantun)
        self.assertEqual(hasil["sentimen"]["label"], "positif")
        self.assertEqual(hasil["emosi_dominan_per_bait"], ["percaya"])

    def test_emosi_dominan_syair_contoh(self):
        # Puisi 2: Syair Petani
        isi_syair = (
            "Dengarlah kisah seorang petani,\n"
            "Bangun pagi menanam padi,\n"
            "Hujan dan panas tak pernah peduli,\n"
            "Demi keluarga sepenuh hati."
        )
        hasil = self.mesin.analisis_puisi(isi_syair)
        self.assertEqual(hasil["sentimen"]["label"], "positif")
        self.assertEqual(len(hasil["emosi_dominan_per_bait"]), 1)
        self.assertIn(hasil["emosi_dominan_per_bait"][0], ["percaya", "antisipasi", "senang"])

    def test_emosi_dominan_gurindam_dua_bait(self):
        # Puisi 3: Gurindam Lisan (dua bait)
        isi_gurindam = (
            "Barang siapa menjaga lisan,\n"
            "terhindar ia dari kesusahan.\n\n"
            "Barang siapa rajin membaca,\n"
            "luas pikirannya bagai samudra."
        )
        hasil = self.mesin.analisis_puisi(isi_gurindam)
        self.assertEqual(len(hasil["emosi_dominan_per_bait"]), 2)
        # Kedua bait bernilai positif / nasihat
        self.assertEqual(hasil["sentimen"]["label"], "positif")


if __name__ == '__main__':
    unittest.main()
