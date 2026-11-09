// ============================================
// auth.js
// Login dan register melalui auth-service; token browser disimpan oleh utilitas api.js.
// ============================================

// ============================================
// CEK SESSION SAAT HALAMAN DIMUAT
// ============================================

function klaimToken(token) {
    try {
        var bagian = token.split('.');
        if (bagian.length !== 3 || !/^[A-Za-z0-9_-]+$/.test(bagian[0])
            || !/^[A-Za-z0-9_-]+$/.test(bagian[1]) || !/^[A-Za-z0-9_-]+$/.test(bagian[2])) return null;
        var headerPayload = bagian[0].replace(/-/g, '+').replace(/_/g, '/');
        headerPayload += '='.repeat((4 - headerPayload.length % 4) % 4);
        var header = JSON.parse(atob(headerPayload));
        if (!header || header.alg !== 'HS256' || header.typ !== 'JWT') return null;
        var payload = bagian[1].replace(/-/g, '+').replace(/_/g, '/');
        payload += '='.repeat((4 - payload.length % 4) % 4);
        var claims = JSON.parse(decodeURIComponent(escape(atob(payload))));
        if (!claims || typeof claims.sub !== 'string' || typeof claims.username !== 'string'
            || typeof claims.nama !== 'string' || !Number.isFinite(claims.iat)
            || !Number.isFinite(claims.exp) || claims.exp * 1000 <= Date.now()) return null;
        return claims;
    } catch (e) {
        return null;
    }
}

window.addEventListener('DOMContentLoaded', function () {
    var token = ambilToken();
    var claims = token ? klaimToken(token) : null;
    if (!claims) {
        hapusToken();
        tampilkanAreaLogin();
        return;
    }
    // Decoded browser claims only control presentation; protected APIs verify the signature.
    tampilkanAreaPuisi(claims.nama || claims.username);
    muatDaftarPuisi();
});

// ============================================
// LOGIN
// ============================================

function prosesLogin(event) {
    event.preventDefault();

    var username = document.getElementById('login-username').value;
    var password = document.getElementById('login-password').value;

    panggil('/api/auth/login', {
        method: 'POST',
        credentials: 'omit',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            username: username,
            password: password
        })
    })
        .then(function (res) { return res.json(); })
        .then(function (data) {
            if (data.status === 'sukses' && data.data && typeof data.data.token === 'string') {
                if (!simpanToken(data.data.token)) {
                    tampilkanPesan('Token tidak dapat disimpan pada browser ini.', 'error');
                    return;
                }
                tampilkanPesan(data.pesan, 'sukses');
                var claims = klaimToken(data.data.token);
                if (!claims) {
                    hapusToken();
                    tampilkanAreaLogin();
                    tampilkanPesan('Server mengirim token yang tidak valid.', 'error');
                    return;
                }
                tampilkanAreaPuisi(claims.nama || (data.data.user && data.data.user.username) || claims.username);
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

    panggil('/api/auth/register', {
        method: 'POST',
        credentials: 'omit',
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
    hapusToken();
    namaPengguna = '';
    if (typeof timerPollingGaleri !== 'undefined' && timerPollingGaleri) {
        clearTimeout(timerPollingGaleri);
        timerPollingGaleri = null;
    }
    tampilkanAreaLogin();
    var galeri = document.getElementById('galeri-puisi');
    if (galeri) galeri.innerHTML = '';
    tampilkanPesan('Logout berhasil.', 'sukses');
}
