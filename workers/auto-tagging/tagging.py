"""Hasil auto-tagging berbentuk {keyword, kategori} sesuai kontrak/README.md."""
import praproses
import tfidf
from kategori import kategori

_korpus = None


def korpus():
    global _korpus
    if _korpus is None:
        _korpus = tfidf.Korpus.muat()
    return _korpus


def analisis(judul, isi):
    # judul ikut dihitung dan diletakkan di depan, jadi menang saat skor seri
    kata = tfidf.kata_kunci(praproses.token('%s\n%s' % (judul or '', isi or '')), korpus())
    return {'keyword': kata, 'kategori': kategori(kata)}
