<?php
declare(strict_types=1);

namespace Pencarian;

//Client REST OpenSearch tipis di atas curl
class OpenSearch
{
    public function __construct(private readonly string $url = '')
    {
    }

    public function minta(string $metode, string $jalur, ?array $badan = null): array
    {
        $dasar = $this->url !== '' ? $this->url : Konfig::urlOpenSearch();
        $ch = curl_init($dasar . $jalur);
        $opsi = [
            CURLOPT_CUSTOMREQUEST  => $metode,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 2,
            CURLOPT_TIMEOUT        => 5,
            CURLOPT_HTTPHEADER     => ['Content-Type: application/json', 'Accept: application/json'],
        ];
        if ($metode === 'HEAD') {
            $opsi[CURLOPT_NOBODY] = true;
        }
        if ($badan !== null) {
            $opsi[CURLOPT_POSTFIELDS] = json_encode($badan, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
        }
        curl_setopt_array($ch, $opsi);
        $mentah = curl_exec($ch);
        $kode = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        $galat = curl_error($ch);
        curl_close($ch);

        if ($mentah === false) {
            throw new \RuntimeException('OpenSearch tidak terjangkau: ' . $galat);
        }
        $json = json_decode((string) $mentah, true);
        return [$kode, is_array($json) ? $json : []];
    }
}
