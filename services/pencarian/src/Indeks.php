<?php
declare(strict_types=1);

namespace Pencarian;

final class Indeks
{
    //`visibilitas` menentukan boleh tidaknya sebuah puisi muncul di pencarian. Hanya nilai "publik" yang pernah dikembalikan. Dokumen tanpa nilai itu tidak ditemukan.
    public static function definisi(): array
    {
        return [
            'settings' => [
                'number_of_shards'   => 1,
                'number_of_replicas' => 0, // satu node, replika tidak akan pernah ditempatkan
            ],
            'mappings' => [
                'dynamic'    => 'strict',
                'properties' => [
                    'judul'       => ['type' => 'text', 'analyzer' => 'indonesian'],
                    'isi'         => ['type' => 'text', 'analyzer' => 'indonesian'],
                    'penulis'     => [
                        'type'   => 'text',
                        'fields' => ['keyword' => ['type' => 'keyword', 'ignore_above' => 256]],
                    ],
                    'genre'       => ['type' => 'keyword'],
                    'tag'         => ['type' => 'keyword'],
                    'kategori'    => ['type' => 'keyword'],
                    'visibilitas' => ['type' => 'keyword'],
                    'tgl_submit'  => ['type' => 'date', 'format' => 'yyyy-MM-dd||strict_date_optional_time'],
                ],
            ],
        ];
    }

    //Buat indeks jika belum ada. Aman dipanggil bersamaan oleh 2 replika
    public static function pastikan(OpenSearch $os): bool
    {
        [$kode] = $os->minta('HEAD', '/' . Konfig::INDEKS);
        if ($kode === 200) {
            return false;
        }
        [$kode, $badan] = $os->minta('PUT', '/' . Konfig::INDEKS, self::definisi());
        if ($kode === 200 || $kode === 201) {
            return true;
        }
        if (($badan['error']['type'] ?? '') === 'resource_already_exists_exception') {
            return false; //replika lain menang race
        }
        throw new \RuntimeException('Gagal membuat indeks: HTTP ' . $kode . ' ' . json_encode($badan));
    }
}
