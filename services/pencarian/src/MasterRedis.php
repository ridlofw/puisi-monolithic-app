<?php
declare(strict_types=1);

namespace Pencarian;

/**
 * Menemukan master Redis: alamat tersimpan yang masih segar, lalu jawaban Sentinel, lalu node yang ROLE-nya master.
 * Hasil disimpan sebentar di berkas karena setiap request web adalah proses baru; node mati dan "semua mati" juga
 * diingat beberapa detik agar degradasi ke basis data tetap cepat. Tanpa master, replika dipakai untuk membaca saja.
 */
final class MasterRedis
{
    /** @var \Closure(string, int): ?object */
    private \Closure $buka;

    /** @var \Closure(): float */
    private \Closure $jam;

    /**
     * @param list<string> $hosts    node Redis host:port
     * @param list<string> $sentinel Sentinel host:port, kosong berarti tanpa Sentinel
     */
    public function __construct(
        private readonly array $hosts,
        private readonly array $sentinel,
        private readonly string $namaMaster,
        private readonly string $berkas,
        ?\Closure $buka = null,
        ?\Closure $jam = null,
        private readonly float $ttlMaster = 5.0,
        private readonly float $jedaMati = 3.0,
    ) {
        $this->buka = $buka ?? self::bukaRedis(...);
        $this->jam  = $jam ?? static fn (): float => microtime(true);
    }

    /**
     * @param bool $paksa abaikan ingatan "node mati" (dipakai saat menaikkan versi cache yang tidak boleh terlewat)
     * @return ?array{0: object, 1: bool} koneksi dan apakah koneksi itu ke master; null bila tidak ada Redis
     */
    public function cari(bool $paksa = false): ?array
    {
        $sekarang = ($this->jam)();
        $status   = $this->baca();
        if (!$paksa && ($sekarang - (float) ($status['semua'] ?? 0)) < $this->jedaMati) {
            return null;
        }
        $mati = [];
        if (!$paksa) {
            foreach ((array) ($status['mati'] ?? []) as $alamat => $waktu) {
                if (is_numeric($waktu) && ($sekarang - (float) $waktu) < $this->jedaMati) {
                    $mati[(string) $alamat] = (float) $waktu;
                }
            }
        }

        $tersimpan = $status['master'] ?? null;
        if (is_string($tersimpan) && !isset($mati[$tersimpan])
            && ($sekarang - (float) ($status['t'] ?? 0)) < $this->ttlMaster) {
            $koneksi = $this->sambung($tersimpan, $mati, $sekarang);
            if ($koneksi !== null) {
                return [$koneksi, true];
            }
        }

        $urutan = $this->hosts;
        $dariSentinel = $this->tanyaSentinel($mati, $sekarang);
        if ($dariSentinel !== null) {
            array_unshift($urutan, $dariSentinel);
        }

        $cadangan = null;
        foreach (array_values(array_unique($urutan)) as $alamat) {
            if (isset($mati[$alamat])) {
                continue;
            }
            $koneksi = $this->sambung($alamat, $mati, $sekarang);
            if ($koneksi === null) {
                continue;
            }
            if (self::peran($koneksi) === 'master') {
                $this->tulis(['master' => $alamat, 't' => $sekarang, 'mati' => $mati]);
                return [$koneksi, true];
            }
            $cadangan ??= $koneksi;
        }

        $this->tulis($cadangan === null ? ['semua' => $sekarang, 'mati' => $mati] : ['mati' => $mati]);
        return $cadangan === null ? null : [$cadangan, false];
    }

    /** Alamat master tersimpan tidak dipercaya lagi, misalnya karena penulisan dijawab READONLY. */
    public function lupakan(): void
    {
        $status = $this->baca();
        unset($status['master'], $status['t']);
        $this->tulis($status);
    }

    /** @param array<string, float> $mati */
    private function sambung(string $alamat, array &$mati, float $sekarang): ?object
    {
        [$host, $port] = array_pad(explode(':', $alamat, 2), 2, '6379');
        $koneksi = ($this->buka)($host, (int) $port);
        if ($koneksi === null) {
            $mati[$alamat] = $sekarang;
        }
        return $koneksi;
    }

    /** @param array<string, float> $mati */
    private function tanyaSentinel(array &$mati, float $sekarang): ?string
    {
        foreach ($this->sentinel as $alamat) {
            if (isset($mati[$alamat])) {
                continue;
            }
            $koneksi = $this->sambung($alamat, $mati, $sekarang);
            if ($koneksi === null) {
                continue;
            }
            try {
                $jawab = $koneksi->rawCommand('SENTINEL', 'get-master-addr-by-name', $this->namaMaster);
            } catch (\Throwable) {
                continue;
            }
            if (is_array($jawab) && count($jawab) >= 2 && is_string($jawab[0]) && $jawab[0] !== '') {
                return $jawab[0] . ':' . $jawab[1];
            }
        }
        return null;
    }

    private static function peran(object $koneksi): string
    {
        try {
            $jawab = $koneksi->rawCommand('ROLE');
        } catch (\Throwable) {
            return '';
        }
        return is_array($jawab) && isset($jawab[0]) ? (string) $jawab[0] : '';
    }

    /** @return array<string, mixed> */
    private function baca(): array
    {
        $isi = @file_get_contents($this->berkas);
        if (!is_string($isi) || $isi === '') {
            return [];
        }
        $data = json_decode($isi, true);
        return is_array($data) ? $data : [];
    }

    /** @param array<string, mixed> $status */
    private function tulis(array $status): void
    {
        // tulis ke berkas sementara lalu rename, supaya proses Apache lain tidak membaca berkas setengah jadi
        $sementara = $this->berkas . '.' . getmypid() . '.' . mt_rand();
        if (@file_put_contents($sementara, json_encode($status)) !== false) {
            @rename($sementara, $this->berkas);
        }
    }

    private static function bukaRedis(string $host, int $port): ?\Redis
    {
        try {
            $redis = new \Redis();
            return @$redis->connect($host, $port, 0.25, null, 0, 0.25) ? $redis : null;
        } catch (\Throwable) {
            return null;
        }
    }
}
