"""Logika worker analisis sentimen dan emosi.

Menerima event puisi.dibuat dan menghasilkan event puisi.dianalisis dengan sumber
analisis-emosi.
"""
import os

from analisis import analisis_puisi


def proses(event):
    if os.environ.get('GAGAL_SENGAJA') == '1':
        raise RuntimeError('gagal disengaja untuk menguji DLQ')
    data = event.get('data', {})
    if 'puisi_id' not in data:
        raise ValueError('data tanpa puisi_id')
    isi = data.get('isi') or ''
    hasil = analisis_puisi(isi)
    return [('puisi.dianalisis', {
        'puisi_id': data['puisi_id'],
        'sumber': 'analisis-emosi',
        'hasil': hasil,
    })]
