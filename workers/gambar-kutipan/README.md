# Worker Gambar Kutipan (Fitur Lanjutan Opsional)

Worker consumer asinkron berbasis Node.js dan Jimp untuk merender teks kutipan puisi ke atas gambar latar dan mengunggahnya ke object storage S3.

## 1. Cara Kerja

- Mengonsumsi antrean `q.gambar-kutipan` yang terikat ke exchange `puisi.events` dengan routing key `puisi.dibuat`.
- Membaca judul, isi puisi, penulis, dan template latar.
- Menghasilkan gambar kutipan berformat `.jpeg` dengan resolusi sesuai template dan overlay gelap.
- Mengunggah berkas gambar ke bucket S3.
- Menerbitkan event hasil `puisi.dianalisis` dengan payload:
  ```json
  {
    "puisi_id": 1,
    "sumber": "gambar-kutipan",
    "hasil": {
      "file_gambar": "puisi_1.jpeg"
    }
  }
  ```

## 2. Pengujian

Menjalankan unit test render kutipan:
```bash
npm test
```
Template latar yang tidak ditemukan akan melempar exception sehingga pesan gagal dipindahkan ke `q.gambar-kutipan.dlq` setelah 3 kali percobaan.
