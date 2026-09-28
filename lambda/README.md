# Microservice Gambar Puisi (AWS Lambda)

Kode fungsi penghasil gambar puisi. Ditulis oleh Ridlo Fanata Wicaksana.

Fungsi menerima parameter lewat query string, mengambil template latar dari bucket S3,
mencetak judul, nama penulis, dan penggalan bait di atasnya, lalu mengembalikan JPEG.

## Kontrak

```
/fungsi?action=preview&template=latar1.jpeg&judul=...&penulis=...&kutipan=...
/fungsi?action=save&template=latar1.jpeg&judul=...&penulis=...&kutipan=...
```

| Parameter | Arti |
|---|---|
| `action` | `preview` mengembalikan JPEG biner. `save` mengunggah berkas ke S3 lalu membalas JSON |
| `template` | nama berkas latar di bucket, misalnya `latar1.jpeg`. Bawaan `latar5.jpeg` |
| `judul` | judul puisi, dipotong pada 50 karakter |
| `penulis` | nama penulis, dicetak sebagai `by <nama>` |
| `kutipan` | penggalan bait, maksimal 5 baris dan 150 karakter. Alias `bait` dan `text` juga diterima |

Balasan `save` berbentuk `{"status":"sukses","file_gambar":"puisi_<angka>.jpeg"}`. Pola nama
itu yang divalidasi `server.php` sebelum disimpan ke basis data.

Keluaran gambar berukuran 640 x 360 piksel. Teks dirender pada kanvas 1000 x 562 lalu
diperkecil, supaya hurufnya tetap halus.

## Membangun paket unggahan

```
cd lambda
npm install
zip -r function.zip index.mjs package.json node_modules      # Linux atau macOS
Compress-Archive -Path index.mjs, package.json, node_modules -DestinationPath function.zip -Force
```

Isi arsip harus berada di akar, bukan di dalam folder induk. `node_modules` sengaja tidak
disimpan di repositori karena berukuran sekitar 35 MB.

## Pengaturan di AWS Lambda

| Setelan | Nilai |
|---|---|
| Runtime | Node.js 20.x atau lebih baru |
| Handler | `index.handler` |
| Execution role | `LabRole` |
| Memory | 256 MB atau 512 MB |
| Timeout | minimal 10 detik |
| Function URL | Auth type NONE |
| Variabel lingkungan | `BUCKET_NAME` diisi nama bucket S3 kelompok |

`BUCKET_NAME` wajib diisi. Tanpa itu fungsi memakai nilai bawaan pada kode dan tidak akan
menemukan template.

## Catatan saat berada di belakang CloudFront

Behavior `/fungsi*` memerlukan cache policy yang menyertakan seluruh query string, serta
origin request policy `AllViewerExceptHostHeader`. Tanpa yang kedua, Lambda Function URL
menolak permintaan dengan status 403.

Permintaan `action=save` memakai metode GET, sehingga dua permintaan dengan parameter yang
sama persis dapat dijawab dari cache edge tanpa mengunggah berkas baru. Untuk puisi dengan
judul, penulis, dan bait yang berbeda, hal ini tidak terjadi.
