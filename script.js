// ============================================
// script.js
// Vanilla JS — Komunikasi dengan server.php
// Semua fetch() menyertakan credentials: 'include'
// ============================================

// Base URL backend — sesuaikan dengan lokasi server.php
// Saat di EC2, gunakan: 'http://<IP_PUBLIK>/server.php'
var BASE_URL = 'server.php';

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
    document.getElementById('area-auth').style.display = 'none';
    document.getElementById('area-puisi').style.display = 'block';
    document.getElementById('btn-logout').style.display = 'inline-block';
    document.getElementById('info-user').textContent = 'Login sebagai: ' + nama;
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
            // Kosongkan tabel puisi
            document.getElementById('tbody-puisi').innerHTML = '';
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

    fetch(BASE_URL + '?aksi=submit_puisi', {
        method: 'POST',
        credentials: 'include',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            judul: judul,
            tgl_submit: tgl_submit,
            isi: isi,
            kategori: kategori,
            keyword: keyword
        })
    })
        .then(function (res) { return res.json(); })
        .then(function (data) {
            if (data.status === 'sukses') {
                tampilkanPesan(data.pesan, 'sukses');
                document.getElementById('form-puisi').reset();
                // Reset tanggal ke hari ini
                document.getElementById('puisi-tgl').value = new Date().toISOString().split('T')[0];
                // Muat ulang daftar puisi
                muatDaftarPuisi();
            } else {
                tampilkanPesan(data.pesan, 'error');
            }
        })
        .catch(function (err) {
            tampilkanPesan('Gagal mengirim puisi: ' + err.message, 'error');
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
            var tbody = document.getElementById('tbody-puisi');
            tbody.innerHTML = '';

            if (data.status === 'sukses' && data.data && data.data.length > 0) {
                for (var i = 0; i < data.data.length; i++) {
                    var p = data.data[i];
                    var tr = document.createElement('tr');

                    var tdNo = document.createElement('td');
                    tdNo.textContent = i + 1;

                    var tdTgl = document.createElement('td');
                    tdTgl.textContent = p.tgl_submit;

                    var tdJudul = document.createElement('td');
                    tdJudul.textContent = p.judul;

                    var tdKat = document.createElement('td');
                    tdKat.textContent = p.kategori;

                    var tdPenulis = document.createElement('td');
                    tdPenulis.textContent = p.penulis;

                    tr.appendChild(tdNo);
                    tr.appendChild(tdTgl);
                    tr.appendChild(tdJudul);
                    tr.appendChild(tdKat);
                    tr.appendChild(tdPenulis);

                    tbody.appendChild(tr);
                }
            } else if (data.status === 'sukses') {
                var tr = document.createElement('tr');
                var td = document.createElement('td');
                td.colSpan = 5;
                td.textContent = 'Belum ada puisi.';
                tr.appendChild(td);
                tbody.appendChild(tr);
            } else {
                tampilkanPesan(data.pesan, 'error');
            }
        })
        .catch(function (err) {
            tampilkanPesan('Gagal memuat daftar puisi: ' + err.message, 'error');
        });
}
