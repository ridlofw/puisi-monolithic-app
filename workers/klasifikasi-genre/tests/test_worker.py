import json
import os
import sys
import unittest
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import amplop  # noqa: E402
import proses  # noqa: E402
import worker  # noqa: E402
from metrik import Metrik  # noqa: E402


PUISI = {
    'puisi_id': 1,
    'judul': 'Pagi di Ladang',
    'isi': 'Pergi ke pasar membeli padi,\nPulang ke rumah membawa pinang,\n'
           'Jika engkau berbaik hati,\nHidup bersama terasa tenang.',
}


def event_contoh(**data):
    return amplop.buat('puisi.dibuat', data or dict(PUISI), 'cid-uji')


class KanalPalsu(object):
    def __init__(self):
        self.ack, self.nack, self.reject = [], [], []

    def basic_ack(self, delivery_tag):
        self.ack.append(delivery_tag)

    def basic_nack(self, delivery_tag, requeue):
        self.nack.append((delivery_tag, requeue))

    def basic_reject(self, delivery_tag, requeue):
        self.reject.append((delivery_tag, requeue))


class TestAmplop(unittest.TestCase):
    def test_buat_mengisi_semua_field_kontrak(self):
        e = amplop.buat('puisi.dianalisis', {'puisi_id': 7}, 'abc')
        self.assertEqual(set(e), set(amplop.WAJIB))
        self.assertEqual(e['tipe'], 'puisi.dianalisis')
        self.assertEqual(e['versi'], 1)
        self.assertEqual(e['correlation_id'], 'abc')

    def test_buat_tanpa_correlation_id_membuat_yang_baru(self):
        self.assertTrue(amplop.buat('x', {}, None)['correlation_id'])

    def test_baca_bolak_balik(self):
        e = event_contoh(puisi_id=3, judul='Senja', isi='Senja tiba')
        self.assertEqual(amplop.baca(amplop.ke_bytes(e)), e)

    def test_baca_menolak_body_rusak(self):
        for body in (b'{"bukan": "amplop"', b'[]', b'{"data": {}}',
                     json.dumps(dict(event_contoh(), data='teks')).encode()):
            with self.assertRaises(amplop.AmplopTidakSah):
                amplop.baca(body)


class TestMetrik(unittest.TestCase):
    def test_histogram_kumulatif_dan_penghitung(self):
        m = Metrik('uji', 'q.uji')
        m.catat(True, 0.07)
        m.catat(False, 3.0)
        teks = m.teks()
        self.assertIn('worker_pesan_diproses_total{worker="uji",queue="q.uji"} 1', teks)
        self.assertIn('worker_pesan_gagal_total{worker="uji",queue="q.uji"} 1', teks)
        self.assertIn('le="0.05"} 0', teks)
        self.assertIn('le="0.1"} 1', teks)
        self.assertIn('le="5"} 2', teks)
        self.assertIn('le="+Inf"} 2', teks)


class TestProses(unittest.TestCase):
    def tearDown(self):
        os.environ.pop('GAGAL_SENGAJA', None)

    def test_hasil_sesuai_kontrak(self):
        [(rk, data)] = proses.proses(event_contoh())
        self.assertEqual(rk, 'puisi.dianalisis')
        self.assertEqual(data['puisi_id'], 1)
        self.assertEqual(data['sumber'], 'klasifikasi-genre')
        self.assertEqual(data['hasil'], {'genre': 'pantun', 'skema_rima': 'abab'})

    def test_event_sama_hasil_sama(self):
        self.assertEqual(proses.proses(event_contoh()), proses.proses(event_contoh()))

    def test_isi_kosong_bukan_kegagalan(self):
        [(rk, data)] = proses.proses(event_contoh(puisi_id=2, judul='', isi=''))
        self.assertEqual(data['hasil'], {'genre': 'puisi bebas', 'skema_rima': ''})

    def test_data_tanpa_isi(self):
        with self.assertRaises(ValueError):
            proses.proses(event_contoh(puisi_id=4, judul='tanpa isi'))

    def test_isi_bukan_string(self):
        with self.assertRaises(ValueError):
            proses.proses(event_contoh(puisi_id=4, judul='isi angka', isi=123))

    def test_gagal_disengaja(self):
        os.environ['GAGAL_SENGAJA'] = '1'
        with self.assertRaises(RuntimeError):
            proses.proses(event_contoh())

    def test_data_tanpa_puisi_id(self):
        with self.assertRaises(ValueError):
            proses.proses(event_contoh(judul='tanpa id', isi='sebaris kata'))


class TestTangani(unittest.TestCase):
    def setUp(self):
        self.kanal = KanalPalsu()
        self.metrik = Metrik('uji', 'q.uji')
        self.terbit = []
        self.diulang = []
        self.method = SimpleNamespace(delivery_tag=9)
        self.props = SimpleNamespace(headers=None)

    def panggil(self, body, ulangi=None):
        return worker.tangani(self.kanal, self.method, self.props, body, self.metrik,
                              lambda rk, e: self.terbit.append((rk, e)),
                              ulangi or (lambda b, p, n: self.diulang.append(n)))

    def test_sukses_di_ack(self):
        self.assertTrue(self.panggil(amplop.ke_bytes(event_contoh())))
        self.assertEqual(self.kanal.ack, [9])
        self.assertEqual(self.kanal.nack, [])
        self.assertEqual(self.metrik.diproses, 1)

    def test_gagal_pertama_diulang_dengan_penghitung_naik(self):
        self.assertFalse(self.panggil(b'{"bukan": "amplop"'))
        self.assertEqual(self.diulang, [2])
        self.assertEqual(self.kanal.ack, [9])
        self.assertEqual(self.kanal.nack + self.kanal.reject, [])
        self.assertEqual(self.metrik.gagal, 1)

    def test_gagal_kedua_diulang_lagi(self):
        self.props = SimpleNamespace(headers={'x-percobaan': 2})
        self.panggil(b'{"bukan": "amplop"')
        self.assertEqual(self.diulang, [3])

    def test_gagal_ketiga_masuk_dlq(self):
        self.props = SimpleNamespace(headers={'x-percobaan': 3})
        self.panggil(b'{"bukan": "amplop"')
        self.assertEqual(self.diulang, [])
        self.assertEqual(self.kanal.reject, [(9, False)])
        self.assertEqual(self.kanal.ack, [])

    def test_gagal_mengulang_dikembalikan_ke_broker(self):
        def rusak(b, p, n):
            raise IOError('broker putus')
        self.panggil(b'{"bukan": "amplop"', ulangi=rusak)
        self.assertEqual(self.kanal.nack, [(9, True)])
        self.assertEqual(self.kanal.ack, [])

    def test_hasil_diterbitkan_dengan_correlation_id_yang_sama(self):
        self.panggil(amplop.ke_bytes(event_contoh()))
        self.assertEqual(len(self.terbit), 1)
        rk, e = self.terbit[0]
        self.assertEqual(rk, 'puisi.dianalisis')
        self.assertEqual(e['correlation_id'], 'cid-uji')
        self.assertEqual(e['data']['sumber'], 'klasifikasi-genre')
        self.assertEqual(self.kanal.ack, [9])

    def test_gagal_terbit_tidak_di_ack(self):
        def rusak(rk, e):
            raise IOError('broker menolak')
        worker.tangani(self.kanal, self.method, self.props, amplop.ke_bytes(event_contoh()),
                       self.metrik, rusak, lambda b, p, n: self.diulang.append(n))
        self.assertEqual(self.diulang, [2])
        self.assertEqual(self.metrik.diproses, 0)


if __name__ == '__main__':
    unittest.main()

