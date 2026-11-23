<?php
declare(strict_types=1);

namespace Pencarian;

final class QueryBuilder
{
    public const PER_HALAMAN = 10;
    public const HAL_MAKS    = 1000;
    public const Q_MAKS      = 200;
    public const PRIVAT      = 'privat';

    //Susun badan search, syarat visibilitas selalu terpasang dan tidak bisa dimatikan oleh parameter.
    public static function bangun(string $q = '', string $genre = '', string $tag = '', string $hal = ''): array
    {
        ['q' => $q, 'genre' => $genre, 'tag' => $tag, 'hal' => $halaman] = self::parameter($q, $genre, $tag, $hal);

        $filter = [['exists' => ['field' => 'tgl_submit']]];
        if ($genre !== '') {
            $filter[] = ['term' => ['genre' => $genre]];
        }
        if ($tag !== '') {
            $filter[] = ['term' => ['tag' => $tag]];
        }

        //multi_match, bukan query_string, supaya tanda kutip, garis miring, dan operator tidak dianggap sintaks
        $cocok = $q === ''
            ? ['match_all' => new \stdClass()]
            : ['multi_match' => ['query' => $q, 'fields' => ['judul^2', 'isi', 'penulis']]];

        $badan = [
            'from'      => ($halaman - 1) * self::PER_HALAMAN,
            'size'      => self::PER_HALAMAN,
            'track_total_hits' => true,
            '_source'   => ['judul', 'penulis', 'genre', 'tag', 'isi'],
            'query'     => ['bool' => [
                'must'     => [$cocok],
                'filter'   => $filter,
                'must_not' => [['term' => ['visibilitas' => self::PRIVAT]]],
            ]],
            'highlight' => [
                'pre_tags'  => ['<mark>'],
                'post_tags' => ['</mark>'],
                'encoder'   => 'html',
                'fields'    => ['isi' => ['fragment_size' => 150, 'number_of_fragments' => 1]],
            ],
        ];
        if ($q === '') {
            $badan['sort'] = [['tgl_submit' => 'desc'], ['_id' => 'desc']];
        }
        return $badan;
    }

    //Parameter yang sudah dibersihkan. Dipakai untuk menyusun query dan untuk key cache, jadi dua permintaan yang artinya sama selalu menghasilkan nilai yang sama.
    public static function parameter(string $q = '', string $genre = '', string $tag = '', string $hal = ''): array
    {
        return [
            'q'     => mb_substr(trim($q), 0, self::Q_MAKS),
            'genre' => mb_strtolower(trim($genre)),
            'tag'   => mb_strtolower(trim($tag)),
            'hal'   => self::halaman($hal),
        ];
    }

    public static function halaman(string $hal): int
    {
        $hal = trim($hal);
        if ($hal === '') {
            return 1;
        }
        if (!ctype_digit($hal) || (int) $hal < 1 || (int) $hal > self::HAL_MAKS) {
            throw new \InvalidArgumentException('Parameter hal harus bilangan bulat 1 sampai ' . self::HAL_MAKS . '.');
        }
        return (int) $hal;
    }

    //Ubah respons dari _search menjadi bentuk kontrak: [{id, judul, penulis, genre, tag, potongan}].
    public static function hasil(array $respons): array
    {
        $total = $respons['hits']['total']['value'] ?? 0;
        $data  = [];
        foreach ($respons['hits']['hits'] ?? [] as $hit) {
            $s = $hit['_source'] ?? [];
            $potongan = $hit['highlight']['isi'][0] ?? null;
            if ($potongan === null) {

                //tanpa kata yang cocok: awal isi, tetap di escape karena dikirim ke innerHTML
                $potongan = htmlspecialchars(mb_substr((string) ($s['isi'] ?? ''), 0, 150), ENT_QUOTES, 'UTF-8');
            }
            $data[] = [
                'id'       => (int) ($hit['_id'] ?? 0),
                'judul'    => (string) ($s['judul'] ?? ''),
                'penulis'  => (string) ($s['penulis'] ?? ''),
                'genre'    => $s['genre'] ?? null,
                'tag'      => $s['tag'] ?? [],
                'potongan' => $potongan,
            ];
        }
        return ['data' => $data, 'total' => (int) $total];
    }
}
