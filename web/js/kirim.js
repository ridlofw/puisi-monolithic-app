// ============================================
// kirim.js
// Form submit puisi, pilihan template, dan preview gambar
// Pemilik: poem-service (R3 — terhubung ke POST /api/puisi)
// ============================================

// Timer debounce preview
var timerPreview = null;

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

    if (!KONFIG.cdn) {
        gambar.style.display = 'none';
        gambar.removeAttribute('src');
        status.textContent = 'Mode lokal aktif: gambar kutipan diproses asinkron oleh worker.';
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
// PERSIAPAN FORM SAAT HALAMAN DIMUAT
// ============================================

window.addEventListener('DOMContentLoaded', function () {
    // Set tanggal default pada form puisi
    var elTgl = document.getElementById('puisi-tgl');
    if (elTgl) {
        elTgl.value = new Date().toISOString().split('T')[0];
    }

    // Kategori dan keyword bersifat opsional karena diisi otomatis oleh worker auto-tagging bila kosong
    var elKategori = document.getElementById('puisi-kategori');
    if (elKategori) {
        elKategori.removeAttribute('required');
        elKategori.placeholder = 'Opsional — diisi otomatis bila kosong';
    }

    var elKeyword = document.getElementById('puisi-keyword');
    if (elKeyword) {
        elKeyword.removeAttribute('required');
        elKeyword.placeholder = 'Opsional — diisi otomatis bila kosong';
    }

    var elKutipan = document.getElementById('puisi-kutipan');
    if (elKutipan && !KONFIG.cdn) {
        elKutipan.removeAttribute('required');
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
            'Preview CDN tidak aktif pada mode lokal.';
    });
});

// ============================================
// SUBMIT PUISI KE POST /api/puisi
// ============================================

function renderGambarBilaTersedia(judul, kutipan) {
    if (!KONFIG.cdn || kutipan === '') {
        return Promise.resolve(null);
    }

    return fetch(urlGambar('save', {
        template: templateTerpilih(),
        judul: judul,
        penulis: namaPengguna,
        kutipan: kutipan
    }))
        .then(function (res) { return res.json(); })
        .then(function (hasilGambar) {
            if (hasilGambar && hasilGambar.status === 'sukses' && hasilGambar.file_gambar) {
                return hasilGambar.file_gambar;
            }
            return null;
        })
        .catch(function () {
            return null;
        });
}

function prosesSubmitPuisi(event) {
    event.preventDefault();

    var judul = document.getElementById('puisi-judul').value.trim();
    var tgl_submit = document.getElementById('puisi-tgl').value;
    var kategori = document.getElementById('puisi-kategori').value.trim();
    var keyword = document.getElementById('puisi-keyword').value.trim();
    var isi = document.getElementById('puisi-isi').value.trim();
    var kutipan = document.getElementById('puisi-kutipan').value.trim();

    if (judul === '' || isi === '') {
        tampilkanPesan('Judul dan isi puisi wajib diisi.', 'error');
        return false;
    }

    if (KONFIG.cdn && kutipan === '') {
        tampilkanPesan('Bait kutipan wajib diisi karena dicetak di gambar puisi.', 'error');
        return false;
    }

    var tombol = document.getElementById('btn-kirim-puisi');
    tombol.disabled = true;
    tombol.textContent = KONFIG.cdn ? 'Menyimpan gambar...' : 'Mengirim puisi...';

    renderGambarBilaTersedia(judul, kutipan)
        .then(function (namaFileGambar) {
            tombol.textContent = 'Menyimpan puisi...';
            var muatan = {
                judul: judul,
                tgl_submit: tgl_submit,
                isi: isi,
                kategori: kategori !== '' ? kategori : null,
                keyword: keyword !== '' ? keyword : null,
                file_gambar: namaFileGambar
            };

            return panggil('/api/puisi', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(muatan)
            });
        })
        .then(function (res) {
            return res.json().then(function (body) {
                return { kode: res.status, body: body };
            });
        })
        .then(function (hasil) {
            var data = hasil.body || {};
            if ((hasil.kode === 202 || hasil.kode === 200 || hasil.kode === 201) && data.status === 'sukses') {
                tampilkanPesan(
                    data.pesan || 'Puisi diterima dan sedang dianalisis di latar belakang.',
                    'sukses'
                );
                document.getElementById('form-puisi').reset();
                document.getElementById('puisi-tgl').value = new Date().toISOString().split('T')[0];
                perbaruiPreview();
                if (typeof muatDaftarPuisi === 'function') {
                    muatDaftarPuisi();
                }
            } else {
                tampilkanPesan(data.pesan || 'Gagal mengirim puisi.', 'error');
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
