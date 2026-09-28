// ============================================
// script.js
// Vanilla JS — Komunikasi dengan server.php
// Semua fetch() menyertakan credentials: 'include'
// ============================================

// Konfigurasi endpoint. Ubah di sini saja saat pindah lingkungan.
var KONFIG = {
    // Backend PHP di EC2. Saat frontend dilayani dari S3/CloudFront,
    // isi dengan alamat publik EC2, misal 'http://<IP_PUBLIK>/server.php'
    backend: 'server.php',

    // Basis URL CDN. Kosong berarti satu origin dengan halaman ini,
    // yaitu saat frontend sudah dilayani lewat CloudFront
    cdn: '',

    // Path microservice gambar di belakang CloudFront (behavior /fungsi*)
    pathGambar: '/fungsi',

    // Template latar yang dibagikan dosen. Penomorannya memang melompati latar4
    template: ['latar1.jpeg', 'latar2.jpeg', 'latar3.jpeg', 'latar5.jpeg'],

    // Jeda sebelum preview dimuat ulang, supaya tiap ketikan tidak memanggil Lambda
    jedaPreview: 600
};

var BASE_URL = KONFIG.backend;

// Nama penulis yang dicetak di gambar, diisi setelah login
var namaPengguna = '';

// Timer debounce preview
var timerPreview = null;

// ============================================
// UTILITAS
// ============================================

function tampilkanPesan(teks, tipe) {
    var elPesan = document.getElementById('pesan');
    elPesan.textContent = teks;
    elPesan.className = tipe; // 'sukses' atau 'error'
}

function tampilkanAreaLogin() {
    document.getElementById('area-auth').style.display = 'flex';
    document.getElementById('area-puisi').style.display = 'none';
    document.getElementById('btn-logout').style.display = 'none';
    document.getElementById('info-user').textContent = '';
}

function tampilkanAreaPuisi(nama) {
    namaPengguna = nama;
    document.getElementById('area-auth').style.display = 'none';
    document.getElementById('area-puisi').style.display = 'block';
    document.getElementById('btn-logout').style.display = 'inline-block';
    document.getElementById('info-user').textContent = 'Login sebagai: ' + nama;
}

// ============================================
// GAMBAR PUISI (MICROSERVICE LAMBDA VIA CDN)
// ============================================

function urlGambar(aksi, parameter) {
    var query = 'action=' + encodeURIComponent(aksi);
    for (var kunci in parameter) {
        if (parameter.hasOwnProperty(kunci)) {
            query += '&' + kunci + '=' + encodeURIComponent(parameter[kunci]);
        }
    }
    return KONFIG.cdn + KONFIG.pathGambar + '?' + query;
}

function urlAset(namaFile) {
    return KONFIG.cdn + '/' + namaFile;
}

// Ikon garis ditanam langsung, bukan diambil dari CDN ikon,
// supaya dokumen statis di S3 tidak bergantung pada sumber luar
var JALUR_IKON = {
    unduh: ['M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4', 'M7 10l5 5 5-5', 'M12 15V3']
};

function bangunIkon(nama) {
    var NS = 'http://www.w3.org/2000/svg';
    var svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('class', 'ikon');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke', 'currentColor');
    svg.setAttribute('stroke-width', '2');
    svg.setAttribute('stroke-linecap', 'round');
    svg.setAttribute('stroke-linejoin', 'round');
    svg.setAttribute('aria-hidden', 'true');

    var jalur = JALUR_IKON[nama];
    for (var i = 0; i < jalur.length; i++) {
        var path = document.createElementNS(NS, 'path');
        path.setAttribute('d', jalur[i]);
        svg.appendChild(path);
    }
    return svg;
}

function templateTerpilih() {
    var terpilih = document.querySelector('input[name="template"]:checked');
    return terpilih ? terpilih.value : KONFIG.template[0];
}

function bangunPilihanTemplate() {
    var wadah = document.getElementById('pilihan-template');
    if (!wadah) {
        return;
    }
    wadah.innerHTML = '';

    for (var i = 0; i < KONFIG.template.length; i++) {
        var namaFile = KONFIG.template[i];

        var item = document.createElement('label');
        item.className = 'template-item';

        var radio = document.createElement('input');
        radio.type = 'radio';
        radio.name = 'template';
        radio.value = namaFile;
        // pakai atribut supaya pilihan pertama kembali aktif setelah form di-reset
        if (i === 0) {
            radio.setAttribute('checked', 'checked');
        }
        radio.addEventListener('change', perbaruiPreview);

        var gambar = document.createElement('img');
        gambar.src = urlAset(namaFile);
        gambar.alt = 'Template ' + (i + 1);

        var keterangan = document.createElement('span');
        keterangan.textContent = 'Template ' + (i + 1);

        item.appendChild(radio);
        item.appendChild(gambar);
        item.appendChild(keterangan);
        wadah.appendChild(item);
    }
}

// Preview ditunda sebentar supaya tiap ketikan tidak memanggil Lambda
function jadwalkanPreview() {
    clearTimeout(timerPreview);
    timerPreview = setTimeout(perbaruiPreview, KONFIG.jedaPreview);
}

function perbaruiPreview() {
    var judul = document.getElementById('puisi-judul').value.trim();
    var kutipan = document.getElementById('puisi-kutipan').value.trim();
    var gambar = document.getElementById('preview-gambar');
    var status = document.getElementById('status-preview');

    if (judul === '' || kutipan === '') {
        gambar.style.display = 'none';
        gambar.removeAttribute('src');
        status.textContent = 'Isi judul dan bait kutipan untuk melihat preview.';
        return;
    }

    status.textContent = 'Memuat preview...';
    gambar.style.display = 'block';
    gambar.src = urlGambar('preview', {
        template: templateTerpilih(),
        judul: judul,
        penulis: namaPengguna,
        kutipan: kutipan
    });
}

// ============================================
// CEK SESSION SAAT HALAMAN DIMUAT
// ============================================

window.addEventListener('DOMContentLoaded', function () {
    // Set tanggal default pada form puisi
    var elTgl = document.getElementById('puisi-tgl');
    if (elTgl) {
        elTgl.value = new Date().toISOString().split('T')[0];
    }

    // Siapkan pilihan template dan pemicu preview
    bangunPilihanTemplate();
    document.getElementById('puisi-judul').addEventListener('input', jadwalkanPreview);
    document.getElementById('puisi-kutipan').addEventListener('input', jadwalkanPreview);

    var elPreview = document.getElementById('preview-gambar');
    elPreview.addEventListener('load', function () {
        document.getElementById('status-preview').textContent =
            'Preview dari template ' + templateTerpilih() + '.';
    });
    elPreview.addEventListener('error', function () {
        elPreview.style.display = 'none';
        document.getElementById('status-preview').textContent =
            'Gagal memuat preview. Periksa konfigurasi CDN atau microservice gambar.';
    });

    // Cek apakah session masih aktif
    fetch(BASE_URL + '?aksi=cek_session', {
        method: 'GET',
        credentials: 'include'
    })
        .then(function (res) { return res.json(); })
        .then(function (data) {
            if (data.status === 'sukses') {
                tampilkanAreaPuisi(data.data.nama);
                muatDaftarPuisi();
            } else {
                tampilkanAreaLogin();
            }
        })
        .catch(function () {
            tampilkanAreaLogin();
        });
});

// ============================================
// LOGIN
// ============================================

function prosesLogin(event) {
    event.preventDefault();

    var username = document.getElementById('login-username').value;
    var password = document.getElementById('login-password').value;

    fetch(BASE_URL + '?aksi=login', {
        method: 'POST',
        credentials: 'include',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            username: username,
            password: password
        })
    })
        .then(function (res) { return res.json(); })
        .then(function (data) {
            if (data.status === 'sukses') {
                tampilkanPesan(data.pesan, 'sukses');
                tampilkanAreaPuisi(data.data.nama);
                muatDaftarPuisi();
                document.getElementById('form-login').reset();
            } else {
                tampilkanPesan(data.pesan, 'error');
            }
        })
        .catch(function (err) {
            tampilkanPesan('Gagal menghubungi server: ' + err.message, 'error');
        });

    return false;
}

// ============================================
// REGISTER
// ============================================

function prosesRegister(event) {
    event.preventDefault();

    var username = document.getElementById('reg-username').value;
    var password = document.getElementById('reg-password').value;
    var nama = document.getElementById('reg-nama').value;
    var no_id = document.getElementById('reg-noid').value;

    fetch(BASE_URL + '?aksi=register', {
        method: 'POST',
        credentials: 'include',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            username: username,
            password: password,
            nama: nama,
            no_id: no_id
        })
    })
        .then(function (res) { return res.json(); })
        .then(function (data) {
            if (data.status === 'sukses') {
                tampilkanPesan(data.pesan, 'sukses');
                document.getElementById('form-register').reset();
            } else {
                tampilkanPesan(data.pesan, 'error');
            }
        })
        .catch(function (err) {
            tampilkanPesan('Gagal menghubungi server: ' + err.message, 'error');
        });

    return false;
}

// ============================================
// LOGOUT
// ============================================

function logout() {
    fetch(BASE_URL + '?aksi=logout', {
        method: 'GET',
        credentials: 'include'
    })
        .then(function (res) { return res.json(); })
        .then(function (data) {
            tampilkanPesan(data.pesan, 'sukses');
            tampilkanAreaLogin();
            // Kosongkan galeri puisi
            document.getElementById('galeri-puisi').innerHTML = '';
        })
        .catch(function (err) {
            tampilkanPesan('Gagal logout: ' + err.message, 'error');
        });
}

// ============================================
// SUBMIT PUISI
// ============================================

function prosesSubmitPuisi(event) {
    event.preventDefault();

    var judul = document.getElementById('puisi-judul').value;
    var tgl_submit = document.getElementById('puisi-tgl').value;
    var kategori = document.getElementById('puisi-kategori').value;
    var keyword = document.getElementById('puisi-keyword').value;
    var isi = document.getElementById('puisi-isi').value;
    var kutipan = document.getElementById('puisi-kutipan').value.trim();

    if (kutipan === '') {
        tampilkanPesan('Bait kutipan wajib diisi karena dicetak di gambar puisi.', 'error');
        return false;
    }

    var tombol = document.getElementById('btn-kirim-puisi');
    tombol.disabled = true;
    tombol.textContent = 'Menyimpan gambar...';

    // Langkah 1: microservice merender gambar lalu mengunggahnya ke bucket S3
    fetch(urlGambar('save', {
        template: templateTerpilih(),
        judul: judul,
        penulis: namaPengguna,
        kutipan: kutipan
    }))
        .then(function (res) { return res.json(); })
        .then(function (hasilGambar) {
            if (!hasilGambar || hasilGambar.status !== 'sukses' || !hasilGambar.file_gambar) {
                throw new Error('Microservice gambar tidak mengembalikan nama file.');
            }

            // Langkah 2: metadata puisi dan nama file gambar dikirim ke backend di EC2
            tombol.textContent = 'Menyimpan puisi...';
            return fetch(BASE_URL + '?aksi=submit_puisi', {
                method: 'POST',
                credentials: 'include',
                headers: { 'Content-Type': 'application/json' },
                // field mengikuti daftar di penugasan, bait kutipan tidak ikut
                // karena hanya dipakai untuk merender gambar
                body: JSON.stringify({
                    judul: judul,
                    tgl_submit: tgl_submit,
                    isi: isi,
                    kategori: kategori,
                    keyword: keyword,
                    file_gambar: hasilGambar.file_gambar
                })
            });
        })
        .then(function (res) { return res.json(); })
        .then(function (data) {
            if (data.status === 'sukses') {
                tampilkanPesan(data.pesan, 'sukses');
                document.getElementById('form-puisi').reset();
                // Reset tanggal ke hari ini
                document.getElementById('puisi-tgl').value = new Date().toISOString().split('T')[0];
                // Kosongkan kembali preview
                perbaruiPreview();
                // Muat ulang daftar puisi
                muatDaftarPuisi();
            } else {
                tampilkanPesan(data.pesan, 'error');
            }
        })
        .catch(function (err) {
            tampilkanPesan('Gagal mengirim puisi: ' + err.message, 'error');
        })
        .then(function () {
            tombol.disabled = false;
            tombol.textContent = 'Kirim Puisi';
        });

    return false;
}

// ============================================
// DAFTAR PUISI
// ============================================

function muatDaftarPuisi() {
    fetch(BASE_URL + '?aksi=daftar_puisi', {
        method: 'GET',
        credentials: 'include'
    })
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
