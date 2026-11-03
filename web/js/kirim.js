// ============================================
// kirim.js
// Form submit puisi, pilihan template, dan preview gambar
// Pemilik: poem-service. Masih memakai backend monolit sampai /api/puisi siap
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
});

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

            // Langkah 2: metadata puisi dan nama file gambar dikirim ke backend
            tombol.textContent = 'Menyimpan puisi...';
            return panggil(BASE_URL + '?aksi=submit_puisi', {
                method: 'POST',
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
