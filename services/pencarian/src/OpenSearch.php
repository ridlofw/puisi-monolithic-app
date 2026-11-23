<?php
declare(strict_types=1);

namespace Pencarian;

//Client REST OpenSearch tipis di atas curl
class OpenSearch
{
    public const TUJUAN = 'opensearch';

    //$pemutus dipasang untuk request web saja; consumer tetap mencoba agar event diulang lewat antrean
    public function __construct(private readonly string $url = '', private readonly ?Pemutus $pemutus = null)
    {
    }

    public function minta(string $metode, string $jalur, ?array $badan = null): array
    {
        if ($this->pemutus !== null && !$this->pemutus->bolehCoba(self::TUJUAN)) {
            throw new PemutusTerbuka('Circuit breaker OpenSearch terbuka, gagal cepat.');
        }
        try {
            [$kode, $json] = $this->kirim($metode, $jalur, $badan);
        } catch (\Throwable $e) {
            $this->pemutus?->gagal(self::TUJUAN);
            throw $e;
        }
        if ($kode >= 500 || $kode === 0) {
            $this->pemutus?->gagal(self::TUJUAN);
        } else {
            $this->pemutus?->sukses(self::TUJUAN);
        }
        return [$kode, $json];
    }

    private function kirim(string $metode, string $jalur, ?array $badan): array
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
