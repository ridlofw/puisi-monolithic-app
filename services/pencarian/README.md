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

## Uji

```
docker compose run --rm --no-deps search-service vendor/bin/phpunit
docker compose exec -T search-service php bin/indeks_contoh.php     # data contoh langsung ke indeks
python scripts/kirim_event.py puisi.dibuat services/pencarian/data/event-dibuat-publik.json
```
