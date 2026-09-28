# Aplikasi Puisi — Monolitik Stateful

Proyek ini adalah implementasi sistem **Monolitik Stateful** sederhana yang dibangun untuk memenuhi Penugasan Terstruktur pada mata kuliah **Pengembangan Perangkat Lunak Scalable**. 

Sistem ini didesain sebagai _ground truth_ atau _baseline_ untuk memahami fundamental arsitektur sistem, secara khusus mendemonstrasikan bagaimana aplikasi menyimpan _state_ (sesi pengguna) secara lokal pada server.

## Fitur Utama
1. **Registrasi Akun:** Pendaftaran pengguna baru dengan penyimpanan password yang di-hash (PHP `password_hash`).
2. **Autentikasi (Login/Logout):** Pengelolaan sesi lokal menggunakan eksekusi `session_start()` di PHP.
3. **Manajemen Puisi:** Pengguna yang sudah login dapat membagikan puisi.
4. **Single-Path Routing:** Seluruh logika backend ditangani melalui satu pintu masuk utama (`server.php?aksi=...`).
5. **Observasi Jaringan (Cookie):** Menggunakan `fetch()` API Vanilla JS dengan opsi `credentials: 'include'` untuk memastikan transmisi `PHPSESSID` melalui Header Cookie terjadi dengan lancar.

## Fitur Gambar Puisi (Hands-on Minggu 5)

Setiap puisi kini memiliki gambar kutipan yang dirender oleh microservice di AWS Lambda dan
dilayani lewat CloudFront.

- **Form submit** memiliki kolom *bait kutipan*, pilihan template latar, dan **preview yang
  berubah otomatis** setiap kali judul, bait, atau template diubah.
- **Submit berjalan dua langkah.** Frontend memanggil `action=save` agar microservice merender
  dan mengunggah gambar ke S3, lalu nama file yang dikembalikan dikirim bersama metadata puisi
  ke `server.php`.
- **Daftar puisi tampil sebagai galeri gambar**, lengkap dengan tautan unduh, bukan tabel teks.

### Konfigurasi Endpoint

Semua alamat dikumpulkan pada objek `KONFIG` di bagian atas `script.js`.

| Kunci | Arti | Contoh saat produksi |
|---|---|---|
| `backend` | lokasi `server.php` di EC2 | `http://<IP_PUBLIK>/server.php` |
| `cdn` | basis URL CloudFront. Kosongkan bila halaman ini sudah dilayani CloudFront | `https://<id>.cloudfront.net` |
| `pathGambar` | path behavior microservice | `/fungsi` |
| `template` | daftar file latar di bucket S3 | `latar1`, `latar2`, `latar3`, `latar5` |
| `jedaPreview` | jeda sebelum preview dimuat ulang, dalam milidetik | `600` |

Berkas latar berasal dari dosen dan diunggah ke root bucket S3 oleh bagian infrastruktur,
sehingga thumbnail template maupun gambar hasil render diambil dari domain CloudFront yang sama.

### Kontrak dengan Microservice Gambar

```
/fungsi?action=preview&template=latar1.jpeg&judul=...&penulis=...&kutipan=...
/fungsi?action=save&template=latar1.jpeg&judul=...&penulis=...&kutipan=...
```

`preview` mengembalikan JPEG biner untuk tag `<img>`, sedangkan `save` mengunggah gambar ke S3
lalu mengembalikan `{"status":"sukses","file_gambar":"puisi_xxx.jpeg"}`. Seluruh nilai teks
dikirim melalui `encodeURIComponent`.

### Yang Dibutuhkan dari Backend dan Database

Frontend sudah mengirim dan membaca field `file_gambar`, sehingga sisi backend perlu:

1. Kolom baru pada tabel puisi: `ALTER TABLE puisi ADD COLUMN file_gambar VARCHAR(255) NOT NULL;`
2. Aksi `submit_puisi` menyimpan `file_gambar` dari body JSON.
3. Aksi `daftar_puisi` menyertakan `file_gambar` pada hasil query.

Selama ketiganya belum ada, galeri tetap tampil dengan kartu bertanda "Gambar belum tersedia",
jadi aplikasi tidak rusak saat integrasi dilakukan bertahap.

## Teknologi yang Digunakan
- **Backend:** PHP Murni (Tanpa Framework)
- **Database:** MySQL
- **Frontend:** HTML5, CSS3 (Flexbox Murni), Vanilla JavaScript
- **Konektor DB:** PHP Data Objects (PDO)

## Struktur Direktori
```text
├── index.html       # Antarmuka utama aplikasi
├── style.css        # Desain layout minimalis
├── script.js        # Komunikasi Fetch API Client-Server
├── koneksi.php      # Konfigurasi PDO MySQL
├── server.php       # Controller utama (Single-Path Routing)
└── query.sql        # Skema tabel database (users, puisi)
```

## Panduan Instalasi Lokal
1. Pastikan Anda telah menginstal **XAMPP/MAMP/LAMP** atau web server sejenis dengan PHP dan MySQL.
2. Clone repositori ini ke dalam folder root web server (misalnya: `htdocs/` atau `/var/www/html/`).
3. Buka **phpMyAdmin** (atau terminal MySQL) dan jalankan seluruh isi file `query.sql` untuk membangun skema basis data (`puisi_db`).
4. Sesuaikan kredensial koneksi di `koneksi.php` (username dan password database) apabila berbeda dari default.
5. Buka browser dan akses aplikasi melalui `http://localhost/puisi-monolithic-app/index.html`.

## Panduan Deployment ke AWS EC2 (t2.micro)
1. Buat instance EC2 tipe **t2.micro** dengan OS Linux (misal: Ubuntu atau Amazon Linux).
2. Konfigurasi **Security Group** untuk mengizinkan Inbound traffic pada port **80 (HTTP)** dan **22 (SSH)**.
3. Hubungkan via SSH, lalu instal Apache, PHP, dan MySQL/MariaDB:
   ```bash
   sudo apt update
   sudo apt install apache2 php libapache2-mod-php php-mysql mysql-server -y
   ```
4. Impor `query.sql` ke MySQL di instance EC2 tersebut.
5. Clone/Copy seluruh file proyek ke direktori `/var/www/html/`.
6. Akses IP Publik EC2 melalui web browser.
