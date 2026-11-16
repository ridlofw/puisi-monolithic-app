// ============================================
// pencarian.js
// Kotak pencarian puisi, memanggil GET /api/search
// Pemilik: search-service. Wadahnya ada di index.html (#section-pencarian)
// Hanya puisi publik yang dikembalikan server, frontend tidak ikut menyaring.
// ============================================

var JEDA_KETIK_MS = 300;
var PER_HALAMAN_CARI = 10;

var timerCari = null;
var halamanCari = 1;
var nomorPermintaanCari = 0;

function pasangGayaPencarian() {
    if (document.getElementById('gaya-pencarian')) {
        return;
    }
    var style = document.createElement('style');
    style.id = 'gaya-pencarian';
    style.textContent = [
        '.cari-hasil { display: flex; flex-direction: column; gap: 10px; margin-top: 8px; }',
        '.hasil-puisi { border: 1px solid #e2e8f0; border-radius: 8px; padding: 12px 14px; background: #fff; }',
        '.hasil-puisi h3 { margin: 0 0 2px; font-size: 15px; color: #1a202c; }',
        '.hasil-penulis { margin: 0 0 6px; font-size: 12px; color: #4a5568; }',
        '.hasil-potongan { margin: 0; font-size: 13px; color: #2d3748; white-space: pre-line; }',
        '.hasil-potongan mark { background: #fefcbf; color: inherit; padding: 0 2px; border-radius: 2px; }',
        '.hasil-tag { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }',
        '.hasil-tag button, .hasil-genre { padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 600; }',
        '.hasil-tag button { background: #edf2f7; color: #2d3748; border: 1px solid #cbd5e0; cursor: pointer; }',
        '.hasil-tag button:hover { background: #e2e8f0; }',
        '.hasil-genre { background: #e9d8fd; color: #44337a; border: 1px solid #d6bcfa; margin-left: 6px; }',
        '.cari-halaman { display: flex; gap: 10px; align-items: center; margin-top: 10px; }'
    ].join('\n');
    document.head.appendChild(style);
}

function elCari(id) {
    return document.getElementById(id);
}

function nilaiPencarian() {
    return {
        q: elCari('cari-q').value.trim(),
        genre: elCari('cari-genre').value,
        tag: elCari('cari-tag').value.trim()
    };
}

function jadwalkanPencarian() {
    clearTimeout(timerCari);
    halamanCari = 1;
    timerCari = setTimeout(jalankanPencarian, JEDA_KETIK_MS);
}

function pencarianLangsung() {
    clearTimeout(timerCari);
    halamanCari = 1;
    jalankanPencarian();
}

function kosongkanHasilCari(pesan) {
    elCari('cari-hasil').textContent = '';
    elCari('cari-halaman').textContent = '';
    elCari('cari-status').textContent = pesan || '';
}

// Potongan dari server sudah di-escape dan hanya memuat <mark>. Tetap dibangun ulang sebagai node,
// hanya teks dan <mark> yang diteruskan, supaya halaman aman walau server berubah
function isiPotongan(elemen, html) {
    var dok = new DOMParser().parseFromString('<body>' + html, 'text/html');
    var anak = dok.body.childNodes;
    for (var i = 0; i < anak.length; i++) {
        var n = anak[i];
        if (n.nodeType === 1 && n.tagName === 'MARK') {
            var tanda = document.createElement('mark');
            tanda.textContent = n.textContent;
            elemen.appendChild(tanda);
        } else {
            elemen.appendChild(document.createTextNode(n.textContent));
        }
    }
}

function bangunHasilPuisi(item) {
    var kartu = document.createElement('article');
    kartu.className = 'hasil-puisi';

    var judul = document.createElement('h3');
    judul.textContent = item.judul || 'Tanpa Judul';
    kartu.appendChild(judul);

    var penulis = document.createElement('p');
    penulis.className = 'hasil-penulis';
    penulis.textContent = 'Oleh: ' + (item.penulis || '-');
    if (item.genre) {
        var genre = document.createElement('span');
        genre.className = 'hasil-genre';
        genre.textContent = item.genre;
        penulis.appendChild(genre);
    }
    kartu.appendChild(penulis);

    var potongan = document.createElement('p');
    potongan.className = 'hasil-potongan';
    isiPotongan(potongan, item.potongan || '');
    kartu.appendChild(potongan);

    if (Array.isArray(item.tag) && item.tag.length > 0) {
        var barisTag = document.createElement('div');
        barisTag.className = 'hasil-tag';
        item.tag.forEach(function (t) {
            var tombol = document.createElement('button');
            tombol.type = 'button';
            tombol.textContent = '#' + t;
            tombol.title = 'Cari dengan tag ini';
            tombol.addEventListener('click', function () {
                elCari('cari-tag').value = t;
                pencarianLangsung();
            });
            barisTag.appendChild(tombol);
        });
        kartu.appendChild(barisTag);
    }
    return kartu;
}

function bangunTombolHalaman(teks, tujuan) {
    var tombol = document.createElement('button');
    tombol.type = 'button';
    tombol.textContent = teks;
    tombol.addEventListener('click', function () {
        halamanCari = tujuan;
        jalankanPencarian();
    });
    return tombol;
}

function tampilkanHasilCari(isi, lapisan) {
    var daftar = Array.isArray(isi.data) ? isi.data : [];
    var total = isi.total || 0;
    var hal = isi.hal || 1;
    var wadah = elCari('cari-hasil');
    var navigasi = elCari('cari-halaman');
    wadah.textContent = '';
    navigasi.textContent = '';

    if (daftar.length === 0) {
        elCari('cari-status').textContent = 'Tidak ada puisi yang cocok.';
        return;
    }

    var status = total + ' puisi ditemukan';
    if (lapisan) {
        status += ' (sumber: ' + lapisan + ')';
    }
    elCari('cari-status').textContent = status;

    daftar.forEach(function (item) {
        wadah.appendChild(bangunHasilPuisi(item));
    });

    var jumlahHalaman = Math.ceil(total / PER_HALAMAN_CARI);
    if (jumlahHalaman > 1) {
        if (hal > 1) {
            navigasi.appendChild(bangunTombolHalaman('Sebelumnya', hal - 1));
        }
        var info = document.createElement('span');
        info.textContent = 'Halaman ' + hal + ' dari ' + jumlahHalaman;
        navigasi.appendChild(info);
        if (hal < jumlahHalaman) {
            navigasi.appendChild(bangunTombolHalaman('Berikutnya', hal + 1));
        }
    }
}

function jalankanPencarian() {
    var cari = nilaiPencarian();
    if (cari.q === '' && cari.genre === '' && cari.tag === '') {
        nomorPermintaanCari++; // batalkan jawaban yang masih di jalan
        kosongkanHasilCari('Ketik kata kunci, atau pilih genre atau tag, untuk mencari puisi.');
        return;
    }

    var params = new URLSearchParams();
    if (cari.q) { params.set('q', cari.q); }
    if (cari.genre) { params.set('genre', cari.genre); }
    if (cari.tag) { params.set('tag', cari.tag); }
    if (halamanCari > 1) { params.set('hal', String(halamanCari)); }

    // Jawaban lama yang tiba terlambat tidak boleh menimpa jawaban untuk ketikan terbaru
    var nomor = ++nomorPermintaanCari;
    elCari('cari-status').textContent = 'Mencari...';

    panggil('/api/search?' + params.toString(), { method: 'GET' })
        .then(function (res) {
            var lapisan = res.headers.get('X-Cache-Layer');
            return res.json().then(function (isi) {
                return { ok: res.ok, isi: isi, lapisan: lapisan };
            });
        })
        .then(function (hasil) {
            if (nomor !== nomorPermintaanCari) {
                return;
            }
            if (!hasil.ok || !hasil.isi || hasil.isi.status !== 'sukses') {
                kosongkanHasilCari((hasil.isi && hasil.isi.pesan) || 'Pencarian gagal.');
                return;
            }
            tampilkanHasilCari(hasil.isi, hasil.lapisan);
        })
        .catch(function (err) {
            if (nomor !== nomorPermintaanCari) {
                return;
            }
            kosongkanHasilCari('Gagal menghubungi layanan pencarian: ' + err.message);
        });
}

window.addEventListener('DOMContentLoaded', function () {
    if (!elCari('cari-q')) {
        return;
    }
    pasangGayaPencarian();
    elCari('cari-q').addEventListener('input', jadwalkanPencarian);
    elCari('cari-tag').addEventListener('input', jadwalkanPencarian);
    elCari('cari-genre').addEventListener('change', pencarianLangsung);
    kosongkanHasilCari('Ketik kata kunci, atau pilih genre atau tag, untuk mencari puisi.');
});
