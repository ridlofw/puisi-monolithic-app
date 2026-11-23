# deploy/lambda: gambar kutipan dengan AWS Lambda (Hands-on 1) di dalam deploy

> ## Cara cepat: satu skrip membuat semuanya
> `bash deploy/lambda/siapkan-gambar.sh` membuat **bucket S3 (+ policy publik + website), fungsi Lambda (+ Function URL +
> izin publik), latar, dan distribusi CloudFront (+ kebijakan cache)**, menguji, lalu mencetak `CDN_URL`. Aman diulang;
> `YA=1 bash deploy/lambda/siapkan-gambar.sh hapus` menghapus hanya yang ia buat. Langkahnya (langkah 9) dan hasil uji ada di
> [`docs/PANDUAN-DEPLOY-AWS.md`](../../docs/PANDUAN-DEPLOY-AWS.md). **Dijalankan di AWS 23 November 2026: 2 dari 2 uji lulus.**
> Bagian di bawah ini adalah **jalur manual** bila skrip tidak bisa dipakai.

Bagian ini menyambungkan fungsi `lambda/` (Hands-on 1) ke aplikasi yang berjalan di Swarm.
Yang ditambahkan **di sisi deploy**, tanpa mengubah berkas milik teman:

| Hal | Bagaimana |
|---|---|
| Fungsi Lambda dibuat dari kode `lambda/` | `buat-fungsi.sh` (skrip di folder ini) |
| Frontend tahu alamat gambar | `CDN_URL` disisipkan ke `web/js/api.js` **saat membangun image gateway** (`Dockerfile.gateway`) |
| Gambar dilayani | CloudFront: `/fungsi*` ke Lambda, sisanya ke bucket S3 (seperti Hands-on 1) |

Mengapa lewat `CDN_URL`: `web/js/api.js` menyimpan `cdn: ''`, dan `kirim.js` **mematikan fitur gambar**
selama `cdn` kosong. Mengisinya saat build menjaga berkas milik Pison tetap utuh.

> **Berlaku untuk jalur Swarm** (`deploy/swarm`), karena gambar gateway dibangun dengan `CDN_URL`. Di Docker Compose lokal
> gateway memakai bind mount `web/`, jadi `CDN_URL` tidak berpengaruh; di sana ubah `cdn: ''` menjadi alamat CloudFront
> langsung di `web/js/api.js` **di laptop** (jangan di-commit). Untuk frontend dari S3, lihat `deploy/aws/cloudfront-dua-jalur.sh`.
>
> **Status jujur:** skrip dijalankan di AWS (bagian atas); **jalur manual di bawah ini belum dijalankan**. Lambda tidak
> menggantikan server mana pun; ia menambah satu komponen **tanpa server** yang berskala sendiri
> (AWS menjalankan salinan sebanyak permintaan). Ia tidak ikut dihitung dalam uji "matikan server".

## Yang sudah Anda punya dari Hands-on 1

Bila bucket S3, fungsi Lambda, dan distribusi CloudFront dari Hands-on 1 **masih ada**, Anda hanya
perlu **langkah 4** (isi `CDN_URL`). Periksa dengan: console CloudFront, salin **Distribution domain
name** (`dxxxxxxxx.cloudfront.net`), lalu buka
`https://DOMAIN/fungsi?action=preview&template=latar1.jpeg&judul=Uji&penulis=Ridlo&kutipan=halo`.
Muncul gambar JPEG berarti sudah lengkap.

## Dari nol

### 1. Bucket S3 dan latar

Console S3, **Create bucket** (nama unik, misalnya `puisi-tim-xxxx`), **hilangkan** centang *Block all
public access*, lalu tambahkan bucket policy baca-publik (`s3:GetObject` untuk `*`) seperti di
`Hands-on 1.md` bagian 1. Unggah berkas latar dari dosen: `latar1.jpeg`, `latar2.jpeg`, `latar3.jpeg`,
`latar5.jpeg` (nama yang dipakai `web/js/api.js`). Berkas latar **tidak ada di repositori**.

### 2. Fungsi Lambda

Di server pertama (yang sudah punya AWS CLI) atau AWS CloudShell. Perlu Node.js dan `zip`
(`sudo apt-get install -y nodejs npm zip` di Ubuntu; CloudShell biasanya sudah ada):

```bash
cd ~/puisi-monolithic-app
export BUCKET_NAME=nama-bucket-anda
bash deploy/lambda/buat-fungsi.sh
```

Skrip mencetak **Function URL** dan perintah `curl` untuk mengujinya. Jawaban `200` berarti fungsi hidup.
Region fungsi **harus sama** dengan region bucket (`lambda/index.mjs` bawaannya `us-east-1`).

### 3. CloudFront (satu alamat untuk gambar)

Ikuti `Hands-on 1.md` Tahap 3. Intinya, satu distribusi dengan dua origin:

| Behavior | Origin | Catatan |
|---|---|---|
| `/fungsi*` | Lambda Function URL (tanpa `https://` dan tanpa `/` di akhir) | cache policy yang menyertakan **semua query string**, origin request policy **AllViewerExceptHostHeader** (tanpa ini 403) |
| Default (`*`) | bucket S3 (endpoint website) | melayani `puisi_*.jpeg` dan `latar*.jpeg` |

### 4. Pasang ke aplikasi

Bangun ulang image gateway dengan alamat CloudFront (di server manager):

```bash
cd ~/puisi-monolithic-app
export REGISTRY=...  TAG=v2             # TAG baru supaya Swarm mau mengganti image
export CDN_URL=https://dxxxxxxxx.cloudfront.net
bash deploy/swarm/skrip/bangun-image.sh        # (tambahkan ECR=1 bila memakai ECR)
docker service update --image "$REGISTRY/puisi-gateway:$TAG" puisi_gateway
```

Buka aplikasi lewat ALB, halaman kirim puisi: pratinjau gambar muncul saat judul dan bait diisi.

## Bila gagal

| Gejala | Kemungkinan penyebab | Tindakan |
|---|---|---|
| `create-function` gagal `AccessDenied` / role | `LabRole` tidak ada atau tidak boleh dipakai | Lihat nama role di IAM; atur `ROLE_ARN` |
| Function URL menjawab `403 Forbidden` | Izin publik belum lengkap | Console Lambda, tab **Configuration**, **Permissions**, tambahkan dua kebijakan berbasis sumber daya untuk Function URL (`lambda:InvokeFunctionUrl` dan `lambda:InvokeFunction`, principal `*`, auth NONE) |
| `Template 'latar1.jpeg' tidak ditemukan` (500) | Berkas latar belum di bucket, atau `BUCKET_NAME` salah | Unggah latar; periksa variabel lingkungan fungsi |
| Lewat CloudFront `403`, langsung ke Function URL `200` | Origin request policy belum `AllViewerExceptHostHeader` | `Hands-on 1.md` Tahap 3 |
| Pratinjau tidak muncul di aplikasi | `CDN_URL` kosong saat build | `docker service update` memakai image lama; bangun ulang dengan `CDN_URL` dan `TAG` baru |
| `save` memakai nama yang sama berulang | `action=save` memakai GET sehingga bisa dicache CloudFront | Lihat `lambda/README.md` bagian CloudFront |

## Kaitan dengan "banyak server" dan SPOF

- Lambda dan S3 adalah layanan terkelola AWS lintas zona; tidak ada server milik Anda di jalur ini.
- Pemanggilnya adalah browser (lewat CloudFront), bukan server Swarm. Jadi mematikan server Swarm
  tidak memengaruhi pembuatan gambar, dan sebaliknya.
- Batas: akses publik pada bucket dan Function URL tanpa autentikasi (sesuai Hands-on 1). Cukup
  untuk sandbox praktik; jangan dipakai begitu saja untuk produksi.
