import json
import os
import sys
import unittest

AKAR_WORKER = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AKAR_REPO = os.path.dirname(os.path.dirname(AKAR_WORKER))
sys.path.insert(0, AKAR_WORKER)

import genre  # noqa: E402
import proses  # noqa: E402
import amplop  # noqa: E402


class TestBunyiAkhirDanSkema(unittest.TestCase):
    def test_bunyi_akhir_vokal_terakhir_dan_konsonan_sesudahnya(self):
        self.assertEqual(genre.bunyi_akhir('Pergi ke pasar membeli padi,'), 'i')
        self.assertEqual(genre.bunyi_akhir('Pulang ke rumah membawa pinang.'), 'ang')
        self.assertEqual(genre.bunyi_akhir('Menyusuri jalan'), 'an')
        self.assertEqual(genre.bunyi_akhir('Di bawah sinar bulan!'), 'an')
        self.assertEqual(genre.bunyi_akhir('Luas pikirannya bagai samudra'), 'a')

    def test_bunyi_akhir_huruf_kapital_dan_tanda_baca(self):
        self.assertEqual(genre.bunyi_akhir('HIDUP BERSAMA TERASA TENANG...?!'), 'ang')
        self.assertEqual(genre.bunyi_akhir('Membeli PADI;'), 'i')

    def test_bunyi_akhir_tanpa_vokal_atau_tanpa_huruf(self):
        self.assertEqual(genre.bunyi_akhir('hmm'), 'hmm')
        self.assertEqual(genre.bunyi_akhir('12345 !!! ...'), '')
        self.assertEqual(genre.bunyi_akhir(''), '')

    def test_skema_bait_dasar(self):
        bait_abab = [
            'Pergi ke pasar membeli padi,',
            'Pulang ke rumah membawa pinang,',
            'Jika engkau berbaik hati,',
            'Hidup bersama terasa tenang.',
        ]
        self.assertEqual(genre.skema_bait(bait_abab), 'abab')

        bait_aaaa = [
            'Dengarlah kisah seorang petani,',
            'Bangun pagi menanam padi,',
            'Hujan dan panas tak pernah peduli,',
            'Demi keluarga sepenuh hati.',
        ]
        self.assertEqual(genre.skema_bait(bait_aaaa), 'aaaa')

        bait_aa = [
            'Barang siapa menjaga lisan,',
            'terhindar ia dari kesusahan.',
        ]
        self.assertEqual(genre.skema_bait(bait_aa), 'aa')


class TestTigaContohPerGenre(unittest.TestCase):
    def test_tiga_contoh_pantun(self):
        contoh_pantun = [
            # Contoh 1: 1 bait abab
            'Pergi ke pasar membeli padi,\n'
            'Pulang ke rumah membawa pinang,\n'
            'Jika engkau berbaik hati,\n'
            'Hidup bersama terasa tenang.',
            # Contoh 2: vokal + konsonan (an / at)
            'Berlayar kapal menuju lautan,\n'
            'Singgah sebentar di tepi darat,\n'
            'Janganlah lupa pada ingatan,\n'
            'Budi yang baik membawa berkat.',
            # Contoh 3: 2 bait pantun
            'Anak ayam turun sepuluh,\n'
            'Mati satu tinggal sembilan,\n'
            'Tuntutlah ilmu bersungguh-sungguh,\n'
            'Supaya engkau tidak ketinggalan.\n\n'
            'Air beriak tanda tak dalam,\n'
            'Air tenang menghanyutkan diri,\n'
            'Bintang bersinar di tengah malam,\n'
            'Jadilah insan yang rendah hati.',
        ]
        SkemaHarapan = ['abab', 'abab', 'abab abab']
        for isi, skema_harapan in zip(contoh_pantun, SkemaHarapan):
            hasil = genre.klasifikasi(isi)
            self.assertEqual(hasil['genre'], 'pantun')
            self.assertEqual(hasil['skema_rima'], skema_harapan)

    def test_tiga_contoh_syair(self):
        contoh_syair = [
            # Contoh 1: rima i
            'Dengarlah kisah seorang petani,\n'
            'Bangun pagi menanam padi,\n'
            'Hujan dan panas tak pernah peduli,\n'
            'Demi keluarga sepenuh hati.',
            # Contoh 2: rima an
            'Wahai muda kenali jalan,\n'
            'Tempat kembali di kemudian,\n'
            'Bekal hidup jangan lupakan,\n'
            'Agar selamat dalam perjalanan.',
            # Contoh 3: 2 bait syair
            'Ilmu itu pelita hati,\n'
            'Cahaya terang di malam sepi,\n'
            'Siapa tekun mencari arti,\n'
            'Hidup mulia sampai nanti.\n\n'
            'Jangan jemu membaca buku,\n'
            'Menambah luas segala ilmu,\n'
            'Hilangkan ragu di dalam kalbu,\n'
            'Masa depan cerah menunggu.',
        ]
        SkemaHarapan = ['aaaa', 'aaaa', 'aaaa aaaa']
        for isi, skema_harapan in zip(contoh_syair, SkemaHarapan):
            hasil = genre.klasifikasi(isi)
            self.assertEqual(hasil['genre'], 'syair')
            self.assertEqual(hasil['skema_rima'], skema_harapan)

    def test_tiga_contoh_gurindam(self):
        contoh_gurindam = [
            # Contoh 1: 1 bait aa
            'Barang siapa menjaga lisan,\n'
            'terhindar ia dari kesusahan.',
            # Contoh 2: 2 bait aa aa
            'Barang siapa menjaga lisan,\n'
            'terhindar ia dari kesusahan.\n\n'
            'Barang siapa rajin membaca,\n'
            'luas pikirannya bagai samudra.',
            # Contoh 3: rima ing
            'Apabila dengki sudah merajai hati,\n'
            'segala kebaikan akan cepat mati.',
        ]
        SkemaHarapan = ['aa', 'aa aa', 'aa']
        for isi, skema_harapan in zip(contoh_gurindam, SkemaHarapan):
            hasil = genre.klasifikasi(isi)
            self.assertEqual(hasil['genre'], 'gurindam')
            self.assertEqual(hasil['skema_rima'], skema_harapan)

    def test_tiga_contoh_puisi_bebas(self):
        contoh_bebas = [
            # Contoh 1: 4 baris tapi rima aabc
            'Hujan turun di kota tua\n'
            'membasuh jalan yang lupa nama\n'
            'aku menunggu di bawah lampu\n'
            'yang cahayanya tak lagi hangat',
            # Contoh 2: 3 baris
            'Aku ingin mencintaimu dengan sederhana\n'
            'dengan kata yang tak sempat diucapkan\n'
            'kayu kepada api yang menjadikannya abu',
            # Contoh 3: 2 baris tapi rima ab
            'Senja turun perlahan di ufuk barat\n'
            'angin malam membawa rindu pulang',
        ]
        for isi in contoh_bebas:
            hasil = genre.klasifikasi(isi)
            self.assertEqual(hasil['genre'], 'puisi bebas')


class TestKasusTepi(unittest.TestCase):
    def test_baris_kosong_berlebih_dan_crlf(self):
        isi = (
            '\r\n\r\n   Pergi ke pasar membeli padi,  \r\n'
            'Pulang ke rumah membawa pinang,\r\n'
            '\r\n   \r\n'
            'Barang siapa menjaga lisan,\r\n'
            'terhindar ia dari kesusahan.\r\n\r\n'
        )
        # Bait 1 punya 2 baris (ab), bait 2 punya 2 baris (aa) -> bukan gurindam murni
        hasil = genre.klasifikasi(isi)
        self.assertEqual(hasil['genre'], 'puisi bebas')
        self.assertEqual(hasil['skema_rima'], 'ab aa')

        # Pantun dengan baris kosong di awal/akhir dan CRLF tetap pantun
        pantun_crlf = (
            '\r\n\r\nPergi ke pasar membeli padi,\r\n'
            'Pulang ke rumah membawa pinang,\r\n'
            'Jika engkau berbaik hati,\r\n'
            'Hidup bersama terasa tenang.\r\n\r\n'
        )
        self.assertEqual(genre.klasifikasi(pantun_crlf), {'genre': 'pantun', 'skema_rima': 'abab'})

    def test_bait_campuran_pantun_dan_syair_menjadi_puisi_bebas(self):
        campuran = (
            'Pergi ke pasar membeli padi,\n'
            'Pulang ke rumah membawa pinang,\n'
            'Jika engkau berbaik hati,\n'
            'Hidup bersama terasa tenang.\n\n'
            'Dengarlah kisah seorang petani,\n'
            'Bangun pagi menanam padi,\n'
            'Hujan dan panas tak pernah peduli,\n'
            'Demi keluarga sepenuh hati.'
        )
        hasil = genre.klasifikasi(campuran)
        self.assertEqual(hasil['genre'], 'puisi bebas')
        self.assertEqual(hasil['skema_rima'], 'abab aaaa')

    def test_puisi_satu_baris_dan_kosong(self):
        self.assertEqual(genre.klasifikasi('Sebaris kata di malam sunyi'),
                         {'genre': 'puisi bebas', 'skema_rima': 'a'})
        self.assertEqual(genre.klasifikasi('   \n\n  '),
                         {'genre': 'puisi bebas', 'skema_rima': ''})


class TestRegresiKontrak(unittest.TestCase):
    def baca_contoh(self, nama):
        jalur = os.path.join(AKAR_REPO, 'kontrak', 'contoh', nama)
        with open(jalur, encoding='utf-8') as f:
            return json.load(f)

    def test_keempat_contoh_puisi_kontrak(self):
        harapan = {
            'pantun.json': {'genre': 'pantun', 'skema_rima': 'abab'},
            'syair.json': {'genre': 'syair', 'skema_rima': 'aaaa'},
            'gurindam.json': {'genre': 'gurindam', 'skema_rima': 'aa aa'},
            'bebas.json': {'genre': 'puisi bebas', 'skema_rima': 'aabc ab'},
        }
        for berkas, target in harapan.items():
            data = self.baca_contoh(berkas)
            self.assertEqual(genre.klasifikasi(data['isi']), target, berkas)

    def test_cocok_dengan_contoh_dianalisis_klasifikasi_genre(self):
        masukan = self.baca_contoh('pantun.json')
        harapan = self.baca_contoh('dianalisis.klasifikasi-genre.json')
        keluaran = proses.proses(amplop.buat('puisi.dibuat', masukan, 'cid-kontrak'))
        self.assertEqual(keluaran, [('puisi.dianalisis', harapan)])


if __name__ == '__main__':
    unittest.main()

