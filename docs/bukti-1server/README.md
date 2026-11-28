# Bukti versi Single (1 server), 28 November 2026

Panduan: [`../PANDUAN-DEPLOY-AWS-1-SERVER.md`](../PANDUAN-DEPLOY-AWS-1-SERVER.md). Semua berkas sudah disaring dari nomor akun, email, dan nama sesi.

| Berkas | Isi | Sumber |
|---|---|---|
| `laptop-single-ram.txt` | `uji_e2e.py` 10 dari 10 dan memori 18 container di laptop (sekitar 3161 MiB) | Docker Desktop laptop Ridlo |
| `aws-cloudshell-28nov.txt` | cek tipe instance, luncurkan, gambar (Lambda, S3, CloudFront), tunggu, kode, bangun, naik (termasuk galat izin SeaweedFS dan perbaikannya), verifikasi (e2e 10 dari 10 dari dalam server), buka, CloudFront dua jalur (8 dari 8), e2e lewat HTTPS (10 dari 10), memori, CloudWatch | log CloudShell; bagian bertanda `[DARI LAYAR]` disalin dari tangkapan layar terminal |
| `aws-cloudshell-28nov-putaran2.txt` | **putaran 2**: hapus semua (sisa 0), lalu deploy dari nol lewat GitHub (commit `21054f6`): `naik` sekali jalan, e2e 10 dari 10 dari server dan lewat HTTPS, CloudFront 8 dari 8, tepat 1 server, 1 bucket, 1 Lambda, 1 CloudFront | log CloudShell |
| `aplikasi-lewat-https-cloudfront.jpg` | halaman Login dan Register lewat alamat HTTPS CloudFront | tab Chrome (tanpa bilah console AWS) |

Kode yang diuji: commit `5e7a453` (branch `ridlo/revisi-handson-3`) ditambah berkas Single yang saat itu belum di-commit
(`deploy/aws/1server.sh`, `deploy/aws/1server/compose.yaml`, `deploy/aws/1server/rabbitmq.conf`, `deploy/aws/cloudfront-dua-jalur.sh` dengan `W_DIR`).
Itu putaran 1. Putaran 2 memakai kode dari GitHub (`ridlo/single-1server`, commit `21054f6`) yang sudah memuat perbaikan `chmod 644 secrets/*` dan alur 1 CloudFront, 1 bucket.
