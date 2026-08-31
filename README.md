# Aplikasi Puisi — Monolitik Stateful

Proyek ini adalah implementasi sistem **Monolitik Stateful** sederhana yang dibangun untuk memenuhi Penugasan Terstruktur pada mata kuliah **Pengembangan Perangkat Lunak Scalable**. 

Sistem ini didesain sebagai _ground truth_ atau _baseline_ untuk memahami fundamental arsitektur sistem, secara khusus mendemonstrasikan bagaimana aplikasi menyimpan _state_ (sesi pengguna) secara lokal pada server.

## Fitur Utama
1. **Registrasi Akun:** Pendaftaran pengguna baru dengan penyimpanan password yang di-hash (PHP `password_hash`).
2. **Autentikasi (Login/Logout):** Pengelolaan sesi lokal menggunakan eksekusi `session_start()` di PHP.
3. **Manajemen Puisi:** Pengguna yang sudah login dapat membagikan puisi.
4. **Single-Path Routing:** Seluruh logika backend ditangani melalui satu pintu masuk utama (`server.php?aksi=...`).
5. **Observasi Jaringan (Cookie):** Menggunakan `fetch()` API Vanilla JS dengan opsi `credentials: 'include'` untuk memastikan transmisi `PHPSESSID` melalui Header Cookie terjadi dengan lancar.

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
