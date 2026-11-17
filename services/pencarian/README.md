# search-service

Pencarian puisi. PHP tanpa framework, OpenSearch lewat REST dengan curl. Pemilik: Evan.

| Proses | Berkas | Tugas |
|---|---|---|
| `search-service` (2 replika) | `public/index.php` | `GET /api/search?q=&genre=&tag=&hal=` |
| `search-consumer` | `bin/consumer.php` | mengonsumsi `q.pencarian-indeks` dan memperbarui indeks |

## Hanya puisi publik yang bisa dicari

Setiap query selalu memuat filter `visibilitas = publik` (`QueryBuilder::bangun`), tidak bisa dimatikan
lewat parameter. Dokumen tanpa nilai `visibilitas` juga tidak pernah muncul. Nilainya datang dari
`data.visibilitas` pada `puisi.dibuat` (`publik` atau `privat`).

- Nilai selain `publik` atau `privat`, atau tidak ada, tidak ditulis. Dokumen baru tetap tersembunyi,
  dokumen lama tidak berubah.
- Puisi yang diubah menjadi privat harus menerbitkan `puisi.dibuat` lagi dengan `visibilitas: "privat"`.
  Consumer menimpa nilainya, dan puisi itu hilang dari pencarian.
- Event analisis tidak pernah menyentuh `visibilitas`.

## Sinkronisasi indeks (eventual consistency)

| Event | Kolom yang ditulis |
|---|---|
| `puisi.dibuat` | `judul`, `isi`, `penulis`, `tgl_submit`, `visibilitas` |
| `puisi.dianalisis` `auto-tagging` | `tag`, `kategori` |
| `puisi.dianalisis` `klasifikasi-genre` | `genre` |
| `puisi.dianalisis` `analisis-emosi`, `audio.siap` | tidak ada, di-ack saja |

Setiap event ditulis lewat `_update` dengan `doc_as_upsert` pada dokumen berid `puisi_id`, dan hanya
menulis kolomnya sendiri. Akibatnya:

- **Urutan event tidak penting.** Hasil analisis yang datang lebih dulu membuat dokumen sebagian, lalu
  `puisi.dibuat` melengkapinya. Dokumen sebagian itu belum bisa dicari karena belum punya `visibilitas`.
- **Idempoten.** Event yang sama dua kali menulis nilai yang sama pada id yang sama, jumlah dokumen tetap.
- **Tidak instan.** OpenSearch me-refresh indeks setiap detik, jadi puisi baru dapat dicari beberapa detik
  setelah event diterima, dan hasil analisis menyusul sesudah worker selesai.

Kegagalan mengikuti kontrak bagian 4: percobaan 1 dan 2 diterbitkan ulang ke queue dengan header
`x-percobaan` naik, percobaan 3 di-reject dan masuk `q.pencarian-indeks.dlq`. Consumer tidak berhenti
saat OpenSearch mati, ia hanya menggagalkan pesannya.

## Cache

Dua lapis, keduanya menjaga aturan "hanya puisi publik" karena yang disimpan adalah jawaban query yang
sudah difilter.

| Lapis | Di mana | TTL | Dibuang oleh |
|---|---|---|---|
| Nginx `proxy_cache` | gateway, key memuat query string | 10 detik | kedaluwarsa |
| Redis cache-aside | search-service, key `cari:v{versi}:{sha1 parameter}` | 120 detik | naiknya `cari:versi` |

- Parameter dibersihkan sebelum di-hash (`QueryBuilder::parameter`), jadi urutan parameter, spasi, dan
  huruf besar kecil tidak membuat entri ganda.
- Consumer menjalankan `INCR cari:versi` setiap kali sebuah event benar-benar mengubah indeks. Key lama tidak
  dihapus, hanya tidak terbaca lagi. Event ganda (OpenSearch menjawab `noop`) tidak membuang cache.
- Consumer menulis dengan `refresh=wait_for`, jadi versi baru hanya naik setelah perubahan bisa dicari.
  Tanpa itu, pencarian yang datang di antara tulis dan refresh akan menyimpan hasil basi di key baru.
- `X-Cache-Layer` bernilai `redis` atau `opensearch`. Lapisan Nginx terlihat di `X-Cache-Status`. Lewat
  gateway, jawaban yang sama dalam 10 detik datang dari Nginx dan membawa `X-Cache-Layer` aslinya,
  jadi untuk menguji Redis panggil search-service langsung.
- Redis mati: `Cache::versi()` mengembalikan null dan pencarian jalan dari OpenSearch. Consumer tidak
  menggagalkan pesan hanya karena Redis, jadi bila Redis tidak terjangkau saat indeks berubah, hasil lama yang
  masih tersimpan hidup paling lama 120 detik.

## Uji

```
docker compose run --rm --no-deps search-service vendor/bin/phpunit
docker compose exec -T search-service php bin/indeks_contoh.php     # data contoh langsung ke indeks
python scripts/kirim_event.py puisi.dibuat services/pencarian/data/event-dibuat-publik.json
```
