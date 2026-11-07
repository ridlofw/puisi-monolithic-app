"""Script pembangun data leksikon InSet dan NRC Emotion Lexicon (Indonesia)."""
import json
import os

DIR_LEKSIKON = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'leksikon')
os.makedirs(DIR_LEKSIKON, exist_ok=True)

# InSet (Indonesian Sentiment Lexicon): kata -> skor float [-1.0, 1.0]
# Skor positif menunjukkan polaritas positif, skor negatif menunjukkan polaritas negatif.
INSET_DATA = {
    # Kata Sangat Positif (+0.7 sampai +1.0)
    "bahagia": 0.9, "gembira": 0.85, "sukacita": 0.9, "cinta": 0.85, "kasih": 0.8,
    "sayang": 0.8, "damai": 0.8, "sejahtera": 0.8, "beruntung": 0.8, "anugerah": 0.85,
    "berkah": 0.85, "sempurna": 0.85, "unggul": 0.8, "juara": 0.8, "hebat": 0.8,
    "luar biasa": 0.9, "indah": 0.75, "elok": 0.7, "pesona": 0.75, "kagum": 0.7,
    "takjub": 0.75, "syukur": 0.8, "terima kasih": 0.75, "mulia": 0.8, "tulus": 0.8,
    "jujur": 0.75, "setia": 0.75, "sahabat": 0.7, "kemenangan": 0.8, "berjaya": 0.8,
    "keberhasilan": 0.8, "berhasil": 0.75, "prestasi": 0.75, "pujian": 0.7, "bangga": 0.75,

    # Kata Positif Menengah (+0.3 sampai +0.65)
    "baik": 0.6, "senang": 0.65, "suka": 0.5, "tenang": 0.6, "nyaman": 0.6,
    "segar": 0.5, "manis": 0.5, "harum": 0.55, "cerah": 0.55, "hangat": 0.5,
    "rajin": 0.6, "pandai": 0.6, "pintar": 0.6, "bijak": 0.65, "cerdas": 0.65,
    "sopan": 0.55, "ramah": 0.6, "peduli": 0.6, "bantu": 0.5, "tolong": 0.5,
    "hidup": 0.45, "tumbuh": 0.4, "mekar": 0.5, "subur": 0.55, "makmur": 0.6,
    "aman": 0.6, "selamat": 0.6, "sehat": 0.65, "kuat": 0.55, "semangat": 0.6,
    "harapan": 0.55, "cita-cita": 0.5, "impian": 0.5, "kebaikan": 0.6, "manfaat": 0.55,
    "faedah": 0.5, "guna": 0.4, "berfaedah": 0.55, "berguna": 0.5, "bersama": 0.4,
    "padi": 0.35, "pinang": 0.35, "rumah": 0.35, "keluarga": 0.5, "kawan": 0.5,
    "teman": 0.5, "cahaya": 0.5, "terang": 0.5, "senyum": 0.6, "tawa": 0.6,
    "fajar": 0.45, "pagi": 0.4, "surga": 0.8, "bidadari": 0.6, "kembang": 0.5,
    "bunga": 0.5, "pelangi": 0.6, "mentari": 0.5, "matahari": 0.45, "samudra": 0.4,

    # Kata Netral Berbobot Rendah (-0.1 sampai +0.1)
    "biasa": 0.0, "cukup": 0.05, "sedang": 0.0, "datang": 0.0, "pergi": 0.0,
    "melihat": 0.0, "duduk": 0.0, "berdiri": 0.0, "jalan": 0.0, "batu": 0.0,
    "air": 0.05, "tanah": 0.0, "daun": 0.05, "pohon": 0.05, "buku": 0.1,
    "kata": 0.0, "suara": 0.0, "waktu": 0.0, "hari": 0.05, "malam": 0.0,

    # Kata Negatif Menengah (-0.3 sampai -0.65)
    "sedih": -0.65, "duka": -0.7, "pilu": -0.65, "kecewa": -0.6, "tangis": -0.55,
    "air mata": -0.5, "sesal": -0.55, "hampa": -0.5, "sunyi": -0.35, "sepi": -0.4,
    "sendiri": -0.25, "lelah": -0.45, "letih": -0.45, "penat": -0.4, "bosan": -0.4,
    "takut": -0.6, "cemas": -0.55, "khawatir": -0.5, "ragu": -0.35, "bimbang": -0.4,
    "gentar": -0.5, "marah": -0.65, "kesal": -0.55, "jengkel": -0.5, "gusar": -0.55,
    "benci": -0.7, "iri": -0.55, "dengki": -0.6, "panas": -0.2, "luka": -0.55,
    "sakit": -0.6, "pedih": -0.6, "perih": -0.55, "susah": -0.5, "kesusahan": -0.6,
    "sulit": -0.4, "berat": -0.35, "gagal": -0.6, "kalah": -0.5, "hilang": -0.5,
    "jatuh": -0.35, "runtuh": -0.55, "patah": -0.5, "kabut": -0.3, "gelap": -0.45,
    "kelam": -0.5, "redup": -0.35, "dingin": -0.3, "pucat": -0.4, "lemah": -0.45,
    "lupa": -0.35, "racun": -0.65, "najis": -0.6, "kotor": -0.5, "hina": -0.65,

    # Kata Sangat Negatif (-0.7 sampai -1.0)
    "durhaka": -0.85, "khianat": -0.9, "jahat": -0.85, "kejam": -0.85, "zalim": -0.9,
    "terkutuk": -0.9, "kutukan": -0.85, "hancur": -0.8, "binasa": -0.85, "musnah": -0.85,
    "maut": -0.8, "kematian": -0.75, "bencana": -0.8, "petaka": -0.85, "malapetaka": -0.9,
    "neraka": -0.9, "siksa": -0.85, "siksaan": -0.85, "derita": -0.8, "penderitaan": -0.8,
    "sengsara": -0.8, "nestapa": -0.85, "laknat": -0.95, "aib": -0.8, "busuk": -0.75
}

# NRC Emotion Lexicon (Bahasa Indonesia): kata -> list emosi
# 8 Emosi dasar: senang, percaya, takut, terkejut, sedih, jijik, marah, antisipasi
NRC_DATA = {
    # senang (joy)
    "bahagia": ["senang"], "gembira": ["senang"], "sukacita": ["senang"],
    "senang": ["senang"], "suka": ["senang"], "tertawa": ["senang"], "tawa": ["senang"],
    "senyum": ["senang"], "riang": ["senang"], "ceria": ["senang"], "pesta": ["senang"],
    "berkah": ["senang", "percaya"], "anugerah": ["senang", "percaya"],
    "damai": ["senang", "percaya"], "tenang": ["senang", "percaya"],
    "cinta": ["senang", "percaya"], "kasih": ["senang", "percaya"], "sayang": ["senang", "percaya"],
    "bunga": ["senang"], "kembang": ["senang"], "mekar": ["senang", "antisipasi"],
    "harum": ["senang"], "manis": ["senang"], "indah": ["senang"], "elok": ["senang"],
    "pesona": ["senang", "terkejut"], "surga": ["senang", "percaya"],
    "pelangi": ["senang", "terkejut"], "mentari": ["senang", "antisipasi"],

    # percaya (trust)
    "percaya": ["percaya"], "setia": ["percaya"], "jujur": ["percaya"],
    "sahabat": ["percaya", "senang"], "teman": ["percaya", "senang"], "kawan": ["percaya"],
    "keluarga": ["percaya", "senang"], "ibu": ["percaya", "kasih", "senang"],
    "ayah": ["percaya"], "guru": ["percaya"], "pemimpin": ["percaya"],
    "aman": ["percaya"], "selamat": ["percaya"], "sehat": ["percaya", "senang"],
    "padi": ["percaya", "antisipasi"], "pinang": ["percaya"], "rumah": ["percaya"],
    "lisan": ["percaya"], "janji": ["percaya"], "tulus": ["percaya"],
    "suci": ["percaya"], "adil": ["percaya"], "benar": ["percaya"],
    "kebenaran": ["percaya"], "iman": ["percaya"], "taat": ["percaya"],
    "patuh": ["percaya"], "hormat": ["percaya"], "baik": ["percaya", "senang"],
    "hati": ["percaya"], "bersama": ["percaya", "senang"], "sepenuh": ["percaya"],
    "peduli": ["percaya", "senang"], "baca": ["percaya", "antisipasi"],
    "samudra": ["percaya", "terkejut"], "pikir": ["percaya", "antisipasi"],

    # takut (fear)
    "takut": ["takut"], "cemas": ["takut"], "khawatir": ["takut"], "gentar": ["takut"],
    "ngeri": ["takut"], "seram": ["takut"], "hantu": ["takut"], "gelap": ["takut", "sedih"],
    "kelam": ["takut", "sedih"], "panik": ["takut", "terkejut"], "bahaya": ["takut"],
    "ancam": ["takut", "marah"], "ancaman": ["takut"], "racun": ["takut", "jijik"],
    "maut": ["takut", "sedih"], "kematian": ["takut", "sedih"], "kubur": ["takut", "sedih"],
    "darah": ["takut", "marah"], "musibah": ["takut", "sedih"], "bencana": ["takut", "sedih"],
    "susah": ["takut", "sedih"], "kesusahan": ["takut", "sedih"], "siksa": ["takut", "sedih"],

    # sedih (sadness)
    "sedih": ["sedih"], "duka": ["sedih"], "pilu": ["sedih"], "tangis": ["sedih"],
    "air mata": ["sedih"], "kecewa": ["sedih"], "sesal": ["sedih"], "hampa": ["sedih"],
    "sepi": ["sedih"], "sunyi": ["sedih"], "sendiri": ["sedih"], "derita": ["sedih"],
    "penderitaan": ["sedih"], "sengsara": ["sedih"], "nestapa": ["sedih"],
    "luka": ["sedih"], "sakit": ["sedih"], "pedih": ["sedih"], "perih": ["sedih"],
    "hilang": ["sedih"], "gugur": ["sedih"], "runtuh": ["sedih"], "patah": ["sedih"],
    "kalah": ["sedih"], "gagal": ["sedih"], "kabut": ["sedih"], "dingin": ["sedih"],
    "redup": ["sedih"], "pucat": ["sedih"], "lemah": ["sedih"], "lupa": ["sedih"],

    # marah (anger)
    "marah": ["marah"], "benci": ["marah"], "kesal": ["marah"], "jengkel": ["marah"],
    "gusar": ["marah"], "geram": ["marah"], "murka": ["marah"], "dendam": ["marah"],
    "lawan": ["marah"], "musuh": ["marah"], "serang": ["marah"], "hantam": ["marah"],
    "robek": ["marah"], "tikam": ["marah"], "kejam": ["marah"], "zalim": ["marah"],
    "panas": ["marah"], "kutuk": ["marah"], "hina": ["marah", "jijik"],

    # terkejut (surprise)
    "kaget": ["terkejut"], "terkejut": ["terkejut"], "heran": ["terkejut"],
    "ajaib": ["terkejut", "senang"], "takjub": ["terkejut", "senang"], "kagum": ["terkejut", "senang"],
    "tiba-tiba": ["terkejut"], "mendadak": ["terkejut"], "petir": ["terkejut", "takut"],
    "guncang": ["terkejut", "takut"], "ganjil": ["terkejut"], "aneh": ["terkejut"],

    # jijik (disgust)
    "jijik": ["jijik"], "kotor": ["jijik"], "busuk": ["jijik"], "najis": ["jijik"],
    "basi": ["jijik"], "lendir": ["jijik"], "muntah": ["jijik"], "bangkai": ["jijik"],
    "sampah": ["jijik"], "noda": ["jijik"], "aib": ["jijik", "sedih"],

    # antisipasi (anticipation)
    "tunggu": ["antisipasi"], "menunggu": ["antisipasi"], "nanti": ["antisipasi"],
    "harap": ["antisipasi", "senang"], "harapan": ["antisipasi", "senang"],
    "cita-cita": ["antisipasi", "senang"], "impian": ["antisipasi", "senang"],
    "esok": ["antisipasi"], "besok": ["antisipasi"], "fajar": ["antisipasi", "senang"],
    "pagi": ["antisipasi", "senang"], "matahari": ["antisipasi", "senang"],
    "jalan": ["antisipasi"], "tuju": ["antisipasi"], "tujuan": ["antisipasi"],
    "siap": ["antisipasi"], "bangun": ["antisipasi"], "rencana": ["antisipasi"],
    "kembali": ["antisipasi"]
}

def main():
    path_inset = os.path.join(DIR_LEKSIKON, 'inset.json')
    with open(path_inset, 'w', encoding='utf-8') as f:
        json.dump(INSET_DATA, f, ensure_ascii=False, indent=2)
    print(f"Tersimpan: {path_inset} ({len(INSET_DATA)} entri)")

    path_nrc = os.path.join(DIR_LEKSIKON, 'nrc_id.json')
    with open(path_nrc, 'w', encoding='utf-8') as f:
        json.dump(NRC_DATA, f, ensure_ascii=False, indent=2)
    print(f"Tersimpan: {path_nrc} ({len(NRC_DATA)} entri)")

if __name__ == '__main__':
    main()
