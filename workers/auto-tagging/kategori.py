"""Kategori puisi dari lima kata kunci dengan leksikon kecil berbentuk kata dasar.

Kata kunci peringkat pertama berbobot 5, peringkat kelima berbobot 1. Kategori dengan bobot
terbesar menang, seri diputus menurut urutan KATEGORI. Tanpa kecocokan, kategorinya umum.
"""
UMUM = 'umum'

# kata dasar hasil stemming Sastrawi, diperiksa oleh tests/test_kategori.py
LEKSIKON = {
    'cinta': {
        'cinta', 'kasih', 'sayang', 'rindu', 'asmara', 'kangen', 'peluk', 'cium', 'setia',
        'mesra', 'jodoh', 'nikah', 'genggam', 'pacar', 'cumbu',
    },
    'alam': {
        'alam', 'gunung', 'laut', 'samudra', 'ombak', 'pantai', 'karang', 'pasir', 'sungai',
        'danau', 'hutan', 'pohon', 'daun', 'bunga', 'rumput', 'embun', 'angin', 'hujan',
        'awan', 'kabut', 'langit', 'bintang', 'matahari', 'senja', 'fajar', 'pelangi',
        'lembah', 'bukit', 'sawah', 'ladang', 'kebun', 'burung', 'bumi', 'padi',
    },
    'ketuhanan': {
        'tuhan', 'allah', 'ilahi', 'doa', 'sujud', 'iman', 'ibadah', 'dosa', 'ampun', 'zikir',
        'masjid', 'gereja', 'surga', 'neraka', 'nabi', 'rasul', 'syukur', 'rahmat', 'takdir',
        'wudu', 'azan', 'pahala', 'hamba', 'tobat', 'puji',
    },
    'perjuangan': {
        'juang', 'merdeka', 'pahlawan', 'bendera', 'bangsa', 'negeri', 'lawan', 'gugur', 'bakti',
        'revolusi', 'jajah', 'tindas', 'perang', 'senjata', 'prajurit', 'bangkit', 'korban',
    },
    'kesedihan': {
        'sedih', 'duka', 'tangis', 'pilu', 'luka', 'sepi', 'pusara', 'makam', 'nestapa', 'lara',
        'perih', 'sendu', 'kecewa', 'patah', 'ratap', 'isak', 'derita', 'sengsara', 'hilang',
    },
    'sosial': {
        'rakyat', 'buruh', 'tani', 'nelayan', 'miskin', 'lapar', 'adil', 'upah', 'gaji', 'harga',
        'pasar', 'dagang', 'pabrik', 'kampung', 'desa', 'warga', 'tetangga', 'gotong', 'royong',
        'rukun', 'sekolah', 'guru', 'masyarakat', 'bantu', 'tolong',
    },
}
KATEGORI = tuple(LEKSIKON)


def kategori(kata_kunci):
    bobot = dict.fromkeys(KATEGORI, 0)
    for i, kata in enumerate(kata_kunci[:5]):
        for k in KATEGORI:
            if kata in LEKSIKON[k]:
                bobot[k] += 5 - i
    terbaik = max(KATEGORI, key=lambda k: (bobot[k], -KATEGORI.index(k)))
    return terbaik if bobot[terbaik] else UMUM
