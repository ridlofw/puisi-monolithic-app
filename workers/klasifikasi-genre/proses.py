"""Logika Klasifikasi Genre: puisi.dibuat menjadi puisi.dianalisis dengan sumber klasifikasi-genre.

Hanya bergantung pada isi event, sehingga event yang sama selalu menghasilkan
hasil yang identik dan aman diproses ulang (idempoten).
"""
import os

import genre

SUMBER = 'klasifikasi-genre'


def proses(event):
    if os.environ.get('GAGAL_SENGAJA') == '1':
        raise RuntimeError('gagal disengaja untuk menguji DLQ')
    data = event['data']
    if 'puisi_id' not in data:
        raise ValueError('data tanpa puisi_id')
    if not isinstance(data.get('isi'), str):
        raise ValueError('data tanpa isi')
    hasil = genre.klasifikasi(data['isi'])
    return [('puisi.dianalisis', {'puisi_id': data['puisi_id'], 'sumber': SUMBER, 'hasil': hasil})]
