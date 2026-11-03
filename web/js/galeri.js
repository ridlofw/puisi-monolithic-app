// ============================================
// galeri.js
// Daftar puisi sebagai galeri gambar
// Pemilik: poem-service. Masih memakai backend monolit sampai /api/puisi siap
// ============================================

function muatDaftarPuisi() {
    panggil(BASE_URL + '?aksi=daftar_puisi', { method: 'GET' })
        .then(function (res) { return res.json(); })
        .then(function (data) {
            var galeri = document.getElementById('galeri-puisi');
            galeri.innerHTML = '';

            if (data.status !== 'sukses') {
                tampilkanPesan(data.pesan, 'error');
                return;
            }

            if (!data.data || data.data.length === 0) {
                var kosong = document.createElement('p');
                kosong.className = 'galeri-kosong';
                kosong.textContent = 'Belum ada puisi.';
                galeri.appendChild(kosong);
                return;
            }

            for (var i = 0; i < data.data.length; i++) {
                galeri.appendChild(bangunKartuPuisi(data.data[i]));
            }
        })
        .catch(function (err) {
            tampilkanPesan('Gagal memuat daftar puisi: ' + err.message, 'error');
        });
}

function bangunKartuPuisi(puisi) {
    var kartu = document.createElement('article');
    kartu.className = 'kartu-puisi';

    if (puisi.file_gambar) {
        var gambar = document.createElement('img');
        gambar.src = urlAset(puisi.file_gambar);
        gambar.alt = 'Gambar puisi ' + puisi.judul;
        gambar.loading = 'lazy';
        gambar.addEventListener('error', function () {
            var pengganti = document.createElement('div');
            pengganti.className = 'kartu-tanpa-gambar';
            pengganti.textContent = 'Gambar gagal dimuat';
            kartu.replaceChild(pengganti, gambar);
        });
        kartu.appendChild(gambar);
    } else {
        // backend lama belum mengirim file_gambar, kartu tetap tampil
        var tanpaGambar = document.createElement('div');
        tanpaGambar.className = 'kartu-tanpa-gambar';
        tanpaGambar.textContent = 'Gambar belum tersedia';
        kartu.appendChild(tanpaGambar);
    }

    var isi = document.createElement('div');
    isi.className = 'kartu-isi';

    // judul dan penulis sudah tercetak di dalam gambar, jadi tidak diulang sebagai teks
    var meta = document.createElement('p');
    meta.className = 'kartu-meta';
    meta.textContent = puisi.tgl_submit + ' | ' + puisi.kategori;

    isi.appendChild(meta);

    if (puisi.file_gambar) {
        var unduh = document.createElement('a');
        unduh.className = 'btn-unduh';
        unduh.href = urlAset(puisi.file_gambar);
        unduh.setAttribute('download', '');
        unduh.appendChild(bangunIkon('unduh'));
        unduh.appendChild(document.createTextNode('Unduh Gambar'));
        isi.appendChild(unduh);
    }

    kartu.appendChild(isi);
    return kartu;
}
