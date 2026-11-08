// ============================================
// galeri.js
// Daftar puisi sebagai galeri dengan chip hasil analisis, audio, & polling 5 detik
// Pemilik: poem-service (R3 — terhubung ke GET /api/puisi)
// ============================================

var timerPollingGaleri = null;
var JEDA_POLLING_MS = 5000;

function pasangGayaGaleri() {
    if (document.getElementById('gaya-galeri-r3')) {
        return;
    }
    var style = document.createElement('style');
    style.id = 'gaya-galeri-r3';
    style.textContent = [
        '.kartu-header-teks { padding: 14px; background: #f7fafc; border-bottom: 1px solid #edf2f7; }',
        '.kartu-judul { margin: 0 0 4px; font-size: 15px; font-weight: 600; color: #1a202c; }',
        '.kartu-penulis { margin: 0 0 8px; font-size: 12px; color: #4a5568; }',
        '.kartu-cuplikan { margin: 0; font-size: 12px; color: #4a5568; white-space: pre-line; font-style: italic; }',
        '.baris-lencana { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; align-items: center; }',
        '.lencana { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 600; }',
        '.lencana-diproses { background: #fefcbf; color: #744210; border: 1px solid #f6e05e; }',
        '.lencana-sebagian { background: #bee3f8; color: #2a4365; border: 1px solid #90cdf4; }',
        '.lencana-selesai { background: #c6f6d5; color: #22543d; border: 1px solid #9ae6b4; }',
        '.chip-genre { background: #e9d8fd; color: #44337a; border: 1px solid #d6bcfa; }',
        '.chip-emosi { background: #fed7e2; color: #702459; border: 1px solid #fbb6ce; }',
        '.chip-kata { background: #edf2f7; color: #2d3748; border: 1px solid #cbd5e0; font-weight: 500; }',
        '.pemutar-audio { width: 100%; height: 34px; margin-top: 8px; }'
    ].join('\n');
    document.head.appendChild(style);
}

function aturPollingGaleri(daftarPuisi) {
    if (timerPollingGaleri) {
        clearTimeout(timerPollingGaleri);
        timerPollingGaleri = null;
    }

    if (!Array.isArray(daftarPuisi) || daftarPuisi.length === 0) {
        return;
    }

    var masihDiproses = false;
    for (var i = 0; i < daftarPuisi.length; i++) {
        var st = daftarPuisi[i] && daftarPuisi[i].status_analisis;
        if (st === 'diproses' || st === 'sebagian') {
            masihDiproses = true;
            break;
        }
    }

    if (masihDiproses) {
        timerPollingGaleri = setTimeout(function () {
            muatDaftarPuisi(true);
        }, JEDA_POLLING_MS);
    }
}

function muatDaftarPuisi(senyap) {
    pasangGayaGaleri();

    panggil('/api/puisi', { method: 'GET' })
        .then(function (res) { return res.json(); })
        .then(function (data) {
            var galeri = document.getElementById('galeri-puisi');
            if (!galeri) {
                return;
            }
            galeri.innerHTML = '';

            if (!data || data.status !== 'sukses') {
                if (!senyap) {
                    tampilkanPesan((data && data.pesan) || 'Gagal memuat daftar puisi.', 'error');
                }
                return;
            }

            var daftar = Array.isArray(data.data) ? data.data : [];
            if (daftar.length === 0) {
                var kosong = document.createElement('p');
                kosong.className = 'galeri-kosong';
                kosong.textContent = 'Belum ada puisi.';
                galeri.appendChild(kosong);
                aturPollingGaleri([]);
                return;
            }

            for (var i = 0; i < daftar.length; i++) {
                galeri.appendChild(bangunKartuPuisi(daftar[i]));
            }

            aturPollingGaleri(daftar);
        })
        .catch(function (err) {
            if (!senyap) {
                tampilkanPesan('Gagal memuat daftar puisi: ' + err.message, 'error');
            }
        });
}

function buatChip(teks, kelasTambahan) {
    var span = document.createElement('span');
    span.className = 'lencana ' + (kelasTambahan || 'chip-kata');
    span.textContent = teks;
    return span;
}

function daftarKataKunci(puisi, autoTag) {
    var hasil = [];
    if (puisi && typeof puisi.keyword === 'string' && puisi.keyword.trim() !== '') {
        var bagian = puisi.keyword.split(',');
        for (var i = 0; i < bagian.length; i++) {
            var k = bagian[i].trim();
            if (k !== '') {
                hasil.push(k);
            }
        }
    } else if (autoTag && Array.isArray(autoTag.keyword)) {
        for (var j = 0; j < autoTag.keyword.length; j++) {
            var kw = String(autoTag.keyword[j] || '').trim();
            if (kw !== '') {
                hasil.push(kw);
            }
        }
    }
    return hasil;
}

function bangunKartuPuisi(puisi) {
    puisi = puisi || {};
    var analisis = (puisi.analisis && typeof puisi.analisis === 'object') ? puisi.analisis : {};
    var infoGenre = analisis['klasifikasi-genre'] || null;
    var infoTag = analisis['auto-tagging'] || null;
    var infoEmosi = analisis['analisis-emosi'] || null;
    var infoGambar = analisis['gambar-kutipan'] || null;

    var fileGambar = puisi.file_gambar || (infoGambar && infoGambar.file_gambar) || null;

    var kartu = document.createElement('article');
    kartu.className = 'kartu-puisi';

    if (fileGambar) {
        var gambar = document.createElement('img');
        gambar.src = urlAset(fileGambar);
        gambar.alt = 'Gambar puisi ' + (puisi.judul || '');
        gambar.loading = 'lazy';
        gambar.addEventListener('error', function () {
            var pengganti = bangunHeaderTeksPuisi(puisi);
            kartu.replaceChild(pengganti, gambar);
        });
        kartu.appendChild(gambar);
    } else {
        kartu.appendChild(bangunHeaderTeksPuisi(puisi));
    }

    var isi = document.createElement('div');
    isi.className = 'kartu-isi';

    var kategoriTampil = puisi.kategori || (infoTag && infoTag.kategori) || 'Tanpa kategori';
    var tglTampil = puisi.tgl_submit || '-';

    var meta = document.createElement('p');
    meta.className = 'kartu-meta';
    meta.textContent = tglTampil + ' | ' + kategoriTampil;
    isi.appendChild(meta);

    // Baris lencana status analisis + genre + emosi
    var barisStatus = document.createElement('div');
    barisStatus.className = 'baris-lencana';

    var statusAnalisis = puisi.status_analisis || 'diproses';
    var kelasStatus = 'lencana-diproses';
    if (statusAnalisis === 'selesai') {
        kelasStatus = 'lencana-selesai';
    } else if (statusAnalisis === 'sebagian') {
        kelasStatus = 'lencana-sebagian';
    }
    barisStatus.appendChild(buatChip('Status: ' + statusAnalisis, kelasStatus));

    if (infoGenre && infoGenre.genre) {
        var teksGenre = 'Genre: ' + infoGenre.genre;
        if (infoGenre.skema_rima) {
            teksGenre += ' (' + infoGenre.skema_rima + ')';
        }
        barisStatus.appendChild(buatChip(teksGenre, 'chip-genre'));
    }

    if (infoEmosi && typeof infoEmosi === 'object') {
        var labelEmosi = infoEmosi.emosi || infoEmosi.sentimen || infoEmosi.emosi_dominan || infoEmosi.label || null;
        if (labelEmosi) {
            barisStatus.appendChild(buatChip('Emosi: ' + labelEmosi, 'chip-emosi'));
        }
    }

    isi.appendChild(barisStatus);

    // Baris chip keyword
    var kataKunci = daftarKataKunci(puisi, infoTag);
    if (kataKunci.length > 0) {
        var barisKeyword = document.createElement('div');
        barisKeyword.className = 'baris-lencana';
        for (var k = 0; k < kataKunci.length; k++) {
            barisKeyword.appendChild(buatChip('#' + kataKunci[k], 'chip-kata'));
        }
        isi.appendChild(barisKeyword);
    }

    // Pemutar audio bila url_audio sudah tersedia
    if (puisi.url_audio) {
        var audio = document.createElement('audio');
        audio.className = 'pemutar-audio';
        audio.controls = true;
        audio.preload = 'none';
        audio.src = puisi.url_audio;
        isi.appendChild(audio);
    }

    if (fileGambar) {
        var unduh = document.createElement('a');
        unduh.className = 'btn-unduh';
        unduh.href = urlAset(fileGambar);
        unduh.setAttribute('download', '');
        unduh.appendChild(bangunIkon('unduh'));
        unduh.appendChild(document.createTextNode('Unduh Gambar'));
        isi.appendChild(unduh);
    }

    kartu.appendChild(isi);
    return kartu;
}

function bangunHeaderTeksPuisi(puisi) {
    var wadah = document.createElement('div');
    wadah.className = 'kartu-header-teks';

    var judul = document.createElement('h3');
    judul.className = 'kartu-judul';
    judul.textContent = puisi.judul || 'Tanpa Judul';
    wadah.appendChild(judul);

    if (puisi.penulis) {
        var penulis = document.createElement('p');
        penulis.className = 'kartu-penulis';
        penulis.textContent = 'Oleh: ' + puisi.penulis;
        wadah.appendChild(penulis);
    }

    if (puisi.isi) {
        var baris = String(puisi.isi).split(/\r?\n/).slice(0, 4).join('\n');
        var cuplikan = document.createElement('p');
        cuplikan.className = 'kartu-cuplikan';
        cuplikan.textContent = baris;
        wadah.appendChild(cuplikan);
    }

    return wadah;
}
