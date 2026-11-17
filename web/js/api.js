// ============================================
// api.js
// Konfigurasi, pembungkus fetch, dan utilitas tampilan bersama
// Dimuat paling awal, sebelum auth.js, kirim.js, galeri.js, pencarian.js
// ============================================

// Konfigurasi endpoint. Ubah di sini saja saat pindah lingkungan.
var KONFIG = {
    // Backend monolit Tugas 1, dilayani gateway lewat profile legacy.
    // Tiap modul pindah ke /api/... milik layanannya masing-masing
    backend: '/legacy/server.php',

    // Basis URL CDN. Kosong berarti satu origin dengan halaman ini,
    // yaitu saat frontend sudah dilayani lewat CloudFront
    cdn: '',

    // Path microservice gambar di belakang CloudFront (behavior /fungsi*)
    pathGambar: '/fungsi',

    // Template latar yang dibagikan dosen. Penomorannya memang melompati latar4
    template: ['latar1.jpeg', 'latar2.jpeg', 'latar3.jpeg', 'latar5.jpeg'],

    // Jeda sebelum preview dimuat ulang, supaya tiap ketikan tidak memanggil Lambda
    jedaPreview: 600,

    // Kunci localStorage tempat JWT dari auth-service disimpan
    kunciToken: 'puisi.token'
};

var BASE_URL = KONFIG.backend;

// Nama penulis yang dicetak di gambar, diisi setelah login
var namaPengguna = '';

// ============================================
// PEMBUNGKUS FETCH
// ============================================

function ambilToken() {
    try {
        return localStorage.getItem(KONFIG.kunciToken);
    } catch (e) {
        return null;
    }
}

function simpanToken(token) {
    try {
        localStorage.setItem(KONFIG.kunciToken, token);
        return true;
    } catch (e) {
        return false;
    }
}

function hapusToken() {
    try {
        localStorage.removeItem(KONFIG.kunciToken);
    } catch (e) {
        // Storage may be disabled by the browser; callers still return to login.
    }
}

// Semua panggilan backend lewat sini. Token dipasang otomatis bila ada,
// jadi modul lain tidak perlu mengurus header Authorization sendiri
function panggil(url, opsi) {
    opsi = opsi || {};
    if (!opsi.credentials) {
        opsi.credentials = 'include';
    }
    opsi.headers = opsi.headers || {};

    var token = ambilToken();
    if (token && !opsi.headers.Authorization) {
        opsi.headers.Authorization = 'Bearer ' + token;
    }
    return fetch(url, opsi);
}

// ============================================
// UTILITAS TAMPILAN
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
