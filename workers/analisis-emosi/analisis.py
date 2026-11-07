"""Modul analisis sentimen dan emosi puisi Indonesia berbasis leksikon."""
import json
import os

from praproses import bersihkan_dan_tokenisasi, dapatkan_stemmer, pisah_bait

DIR_LEKSIKON = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'leksikon')
KATA_NEGASI = {'tidak', 'bukan', 'tak', 'tiada', 'jangan', 'belom', 'belum', 'kurang'}
DAFTAR_EMOSI = ('senang', 'percaya', 'takut', 'terkejut', 'sedih', 'jijik', 'marah', 'antisipasi')


class MesinAnalisis(object):
    """Mesin analisis sentimen dan emosi yang memuat leksikon sekali saat inisialisasi."""

    def __init__(self, dir_leksikon=DIR_LEKSIKON):
        self.inset = self._muat_json(os.path.join(dir_leksikon, 'inset.json'))
        self.nrc = self._muat_json(os.path.join(dir_leksikon, 'nrc_id.json'))
        self.stemmer = dapatkan_stemmer()

    def _muat_json(self, path):
        if not os.path.exists(path):
            return {}
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)

    def cari_skor_kata(self, kata):
        """Cari skor kata di InSet. Jika belum ada, coba stemming Sastrawi."""
        if kata in self.inset:
            return self.inset[kata]
        dasar = self.stemmer.stem(kata)
        if dasar and dasar in self.inset:
            return self.inset[dasar]
        return None

    def cari_emosi_kata(self, kata):
        """Cari daftar emosi kata di NRC. Jika belum ada, coba stemming Sastrawi."""
        if kata in self.nrc:
            return self.nrc[kata]
        dasar = self.stemmer.stem(kata)
        if dasar and dasar in self.nrc:
            return self.nrc[dasar]
        return []

    def analisis_baris(self, baris):
        """Analisis satu baris teks.

        Mengembalikan tuple: (skor_rata2, label, daftar_emosi_ditemukan).
        Negasi sederhana membalik polaritas kata sesudahnya.
        """
        kata_kata = bersihkan_dan_tokenisasi(baris)
        if not kata_kata:
            return 0.0, 'netral', []

        skor_kata_list = []
        emosi_list = []
        negasi_aktif = False

        for kata in kata_kata:
            if kata in KATA_NEGASI:
                negasi_aktif = True
                continue

            skor = self.cari_skor_kata(kata)
            if skor is not None:
                if negasi_aktif:
                    skor = -skor
                    negasi_aktif = False
                skor_kata_list.append(skor)

            emosi = self.cari_emosi_kata(kata)
            if emosi:
                if negasi_aktif:
                    # Negasi pada emosi: jika kata senang dinegasikan, cenderung ke sedih/kecewa
                    emosi_dibalik = []
                    for e in emosi:
                        if e == 'senang':
                            emosi_dibalik.append('sedih')
                        elif e == 'percaya':
                            emosi_dibalik.append('takut')
                        else:
                            emosi_dibalik.append(e)
                    emosi_list.extend(emosi_dibalik)
                    negasi_aktif = False
                else:
                    emosi_list.extend(emosi)

        if not skor_kata_list:
            skor_rata = 0.0
            label = 'netral'
        else:
            skor_rata = sum(skor_kata_list) / len(skor_kata_list)
            # Batasi rentang [-1.0, 1.0]
            skor_rata = max(-1.0, min(1.0, round(skor_rata, 2)))
            if skor_rata > 0.05:
                label = 'positif'
            elif skor_rata < -0.05:
                label = 'negatif'
            else:
                label = 'netral'

        return skor_rata, label, emosi_list

    def tentukan_emosi_dominan(self, daftar_emosi, label_sentimen='netral'):
        """Tentukan emosi dominan dari daftar emosi yang muncul pada suatu bait."""
        if not daftar_emosi:
            if label_sentimen == 'positif':
                return 'percaya'
            elif label_sentimen == 'negatif':
                return 'sedih'
            return 'percaya'

        frekuensi = {}
        for e in daftar_emosi:
            frekuensi[e] = frekuensi.get(e, 0) + 1

        # Urutkan berdasarkan frekuensi terbanyak
        terurut = sorted(frekuensi.items(), key=lambda x: x[1], reverse=True)
        return terurut[0][0]

    def analisis_puisi(self, isi_puisi):
        """Analisis lengkap seluruh teks puisi.

        Mengembalikan dictionary sesuai kontrak:
        {
            "sentimen": {"skor": float, "label": "positif"|"netral"|"negatif"},
            "emosi_dominan_per_bait": [str, ...]
        }
        """
        daftar_bait = pisah_bait(isi_puisi)
        if not daftar_bait:
            return {
                'sentimen': {'skor': 0.0, 'label': 'netral'},
                'emosi_dominan_per_bait': ['percaya']
            }

        semua_skor_baris = []
        emosi_per_bait = []

        for bait in daftar_bait:
            emosi_bait = []
            skor_baris_bait = []
            for baris in bait:
                skor, label, emosi = self.analisis_baris(baris)
                skor_baris_bait.append(skor)
                semua_skor_baris.append(skor)
                emosi_bait.extend(emosi)

            rata_bait = sum(skor_baris_bait) / len(skor_baris_bait) if skor_baris_bait else 0.0
            label_bait = 'positif' if rata_bait > 0.05 else ('negatif' if rata_bait < -0.05 else 'netral')
            emosi_dominan = self.tentukan_emosi_dominan(emosi_bait, label_bait)
            emosi_per_bait.append(emosi_dominan)

        skor_keseluruhan = sum(semua_skor_baris) / len(semua_skor_baris) if semua_skor_baris else 0.0
        skor_keseluruhan = max(-1.0, min(1.0, round(skor_keseluruhan, 2)))
        if skor_keseluruhan > 0.05:
            label_akhir = 'positif'
        elif skor_keseluruhan < -0.05:
            label_akhir = 'negatif'
        else:
            label_akhir = 'netral'

        return {
            'sentimen': {
                'skor': skor_keseluruhan,
                'label': label_akhir
            },
            'emosi_dominan_per_bait': emosi_per_bait
        }


# Instance tunggal yang dimuat sekali saat start
_MESIN_DEFAULT = None


def dapatkan_mesin():
    global _MESIN_DEFAULT
    if _MESIN_DEFAULT is None:
        _MESIN_DEFAULT = MesinAnalisis()
    return _MESIN_DEFAULT


def analisis_puisi(isi_puisi):
    return dapatkan_mesin().analisis_puisi(isi_puisi)
