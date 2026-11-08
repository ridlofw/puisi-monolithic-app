"""Logika Auto-tagging: puisi.dibuat menjadi puisi.dianalisis dengan sumber auto-tagging.

Hanya bergantung pada isi event dan df.json yang dibundel, jadi event yang sama selalu
menghasilkan hasil yang sama dan aman diproses ulang.
"""
import os

import tagging

SUMBER = 'auto-tagging'


def proses(event):
    if os.environ.get('GAGAL_SENGAJA') == '1':
        raise RuntimeError('gagal disengaja untuk menguji DLQ')
    data = event['data']
    if 'puisi_id' not in data:
        raise ValueError('data tanpa puisi_id')
    if not isinstance(data.get('isi'), str):
        raise ValueError('data tanpa isi')
    hasil = tagging.analisis(data.get('judul'), data['isi'])
    return [('puisi.dianalisis', {'puisi_id': data['puisi_id'], 'sumber': SUMBER, 'hasil': hasil})]
