<?php
declare(strict_types=1);

namespace Pencarian;

final class Konfig
{
    public const INDEKS = 'puisi';

    public static function env(string $kunci, string $bawaan = ''): string
    {
        $nilai = getenv($kunci);
        return ($nilai === false || trim($nilai) === '') ? $bawaan : trim($nilai);
    }

    public static function urlOpenSearch(): string
    {
        return rtrim(self::env('OPENSEARCH_URL', 'http://opensearch:9200'), '/');
    }
}
