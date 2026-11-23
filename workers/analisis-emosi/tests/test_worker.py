"""Unit test untuk worker consumer analisis emosi."""
import json
import os
import sys
import unittest
from types import SimpleNamespace

DIR_TESTS = os.path.dirname(os.path.abspath(__file__))
DIR_WORKER = os.path.dirname(DIR_TESTS)
sys.path.insert(0, DIR_WORKER)

import amplop  # noqa: E402
import proses  # noqa: E402
import worker  # noqa: E402
from metrik import Metrik  # noqa: E402


def event_contoh(**data):
    d = {'puisi_id': 1, 'isi': 'Pagi yang indah dan damai.'}
    d.update(data)
    return amplop.buat('puisi.dibuat', d, 'cid-emosi-123')


class KanalPalsu(object):
    def __init__(self):
        self.ack, self.nack, self.reject = [], [], []

    def basic_ack(self, delivery_tag):
        self.ack.append(delivery_tag)

    def basic_nack(self, delivery_tag, requeue):
        self.nack.append((delivery_tag, requeue))

    def basic_reject(self, delivery_tag, requeue):
        self.reject.append((delivery_tag, requeue))


class TestProsesEmosi(unittest.TestCase):
    def tearDown(self):
        os.environ.pop('GAGAL_SENGAJA', None)

    def test_proses_menghasilkan_event_puisi_dianalisis(self):
        hasil = proses.proses(event_contoh(puisi_id=10, isi='Bahagia dan gembira bersama.'))
        self.assertEqual(len(hasil), 1)
        rk, data = hasil[0]
        self.assertEqual(rk, 'puisi.dianalisis')
        self.assertEqual(data['puisi_id'], 10)
        self.assertEqual(data['sumber'], 'analisis-emosi')
        self.assertIn('sentimen', data['hasil'])
        self.assertIn('emosi_dominan_per_bait', data['hasil'])

    def test_gagal_disengaja(self):
        os.environ['GAGAL_SENGAJA'] = '1'
        with self.assertRaises(RuntimeError):
            proses.proses(event_contoh())

    def test_data_tanpa_puisi_id_menolak(self):
        with self.assertRaises(ValueError):
            proses.proses({'data': {'isi': 'puisi tanpa id'}})


class TestTanganiWorkerEmosi(unittest.TestCase):
    def setUp(self):
        self.kanal = KanalPalsu()
        self.metrik = Metrik('analisis-emosi', 'q.analisis-emosi')
        self.terbit = []
        self.diulang = []
        self.method = SimpleNamespace(delivery_tag=1)
        self.props = SimpleNamespace(headers=None)

    def panggil(self, body, ulangi=None):
        return worker.tangani(
            self.kanal, self.method, self.props, body, self.metrik,
            lambda rk, e: self.terbit.append((rk, e)),
            ulangi or (lambda b, p, n: self.diulang.append(n))
        )

    def test_sukses_memproses_dan_menerbitkan_hasil(self):
        body = amplop.ke_bytes(event_contoh(puisi_id=5, isi='Sejahtera dan damai hidup kita.'))
        self.assertTrue(self.panggil(body))
        self.assertEqual(self.kanal.ack, [1])
        self.assertEqual(len(self.terbit), 1)
        rk, event = self.terbit[0]
        self.assertEqual(rk, 'puisi.dianalisis')
        self.assertEqual(event['correlation_id'], 'cid-emosi-123')
        self.assertEqual(event['data']['sumber'], 'analisis-emosi')
        self.assertEqual(self.metrik.diproses, 1)

    def test_gagal_tiga_kali_masuk_dlq(self):
        self.props = SimpleNamespace(headers={'x-percobaan': 3})
        self.assertFalse(self.panggil(b'{"bukan": "amplop valid"}'))
        self.assertEqual(self.kanal.reject, [(1, False)])
        self.assertEqual(self.metrik.gagal, 1)


class TestJedaUlang(unittest.TestCase):
    def test_eksponensial_dengan_batas(self):
        tengah = lambda a, b: (a + b) / 2.0  # noqa: E731
        self.assertEqual([worker.jeda_ulang(n, tengah) for n in (2, 3, 4, 5)], [1, 2, 4, 4])

    def test_jitter_dalam_rentang_dua_puluh_persen(self):
        for n, dasar in ((2, 1), (3, 2)):
            for _ in range(200):
                j = worker.jeda_ulang(n)
                self.assertGreaterEqual(j, dasar * 0.8)
                self.assertLessEqual(j, dasar * 1.2)

    def test_jitter_menyebar_jadwal(self):
        self.assertGreater(len({round(worker.jeda_ulang(3), 3) for _ in range(50)}), 10)


if __name__ == '__main__':
    unittest.main()
