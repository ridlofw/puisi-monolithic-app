// ============================================
// auth.js
// Cek sesi, login, register, logout
// Pemilik: auth-service. Masih memakai backend monolit sampai /api/auth siap
// ============================================

// ============================================
// CEK SESSION SAAT HALAMAN DIMUAT
// ============================================

window.addEventListener('DOMContentLoaded', function () {
    panggil(BASE_URL + '?aksi=cek_session', { method: 'GET' })
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

    panggil(BASE_URL + '?aksi=login', {
        method: 'POST',
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

    panggil(BASE_URL + '?aksi=register', {
        method: 'POST',
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
    panggil(BASE_URL + '?aksi=logout', { method: 'GET' })
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
