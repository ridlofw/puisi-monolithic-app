<?php
declare(strict_types=1);

namespace Pencarian;

/**
 * Circuit breaker per tujuan (Bab 11.2): closed, open, half-open.
 *
 * - closed: permintaan diteruskan, kegagalan beruntun dihitung.
 * - open: setelah AMBANG kegagalan beruntun, tujuan dilewati selama JEDA detik (fail fast).
 * - half-open: setelah JEDA, satu permintaan uji diizinkan; sukses menutup sirkuit,
 *   gagal membukanya lagi.
 *
 * Keadaan disimpan di berkas sementara per container dan dikunci flock, sehingga semua proses
 * Apache dalam satu replika berbagi sirkuit yang sama.
 */
final class Pemutus
{
    public const CLOSED    = 'closed';
    public const OPEN      = 'open';
    public const HALF_OPEN = 'half_open';

    /** @var callable(): float */
    private $jam;

    public function __construct(
        private string $folder = '',
        private int $ambang = 3,
        private float $jeda = 10.0,
        ?callable $jam = null
    ) {
        $this->folder = $folder !== '' ? $folder : sys_get_temp_dir() . '/pemutus';
        $this->jam    = $jam ?? static fn (): float => microtime(true);
        if (!is_dir($this->folder)) {
            @mkdir($this->folder, 0777, true);
        }
    }

    public static function bawaan(): self
    {
        static $p = null;
        return $p ??= new self(
            '',
            (int) Konfig::env('PEMUTUS_AMBANG', '3'),
            (float) Konfig::env('PEMUTUS_JEDA', '10')
        );
    }

    /** Boleh mencoba tujuan ini sekarang? Di half-open hanya satu pemanggil yang mendapat izin. */
    public function bolehCoba(string $tujuan): bool
    {
        return $this->ubah($tujuan, function (array $k): array {
            $sekarang = ($this->jam)();
            if ($k['status'] === self::OPEN) {
                if ($sekarang < $k['buka_sampai']) {
                    return [$k, false];
                }
                $k['status']      = self::HALF_OPEN;
                $k['uji_sampai']  = $sekarang + $this->jeda;
                return [$k, true];
            }
            if ($k['status'] === self::HALF_OPEN) {
                // uji yang macet tanpa laporan dianggap selesai setelah jeda, agar sirkuit tidak tersangkut
                if ($sekarang >= $k['uji_sampai']) {
                    $k['uji_sampai'] = $sekarang + $this->jeda;
                    return [$k, true];
                }
                return [$k, false];
            }
            return [$k, true];
        });
    }

    public function sukses(string $tujuan): void
    {
        $this->ubah($tujuan, function (array $k): array {
            $berubah = $k['status'] !== self::CLOSED;
            $k = self::awal();
            if ($berubah) {
                Log::info('circuit breaker tertutup kembali', ['tujuan' => $this->namaTujuan]);
            }
            return [$k, null];
        });
    }

    public function gagal(string $tujuan): void
    {
        $this->ubah($tujuan, function (array $k): array {
            $sekarang = ($this->jam)();
            $k['gagal']++;
            if ($k['status'] === self::HALF_OPEN || $k['gagal'] >= $this->ambang) {
                if ($k['status'] !== self::OPEN) {
                    Log::peringatan('circuit breaker terbuka', [
                        'tujuan' => $this->namaTujuan,
                        'gagal_beruntun' => $k['gagal'],
                        'jeda_detik' => $this->jeda,
                    ]);
                }
                $k['status']      = self::OPEN;
                $k['buka_sampai'] = $sekarang + $this->jeda;
            }
            return [$k, null];
        });
    }

    public function status(string $tujuan): string
    {
        return $this->ubah($tujuan, static fn (array $k): array => [$k, $k['status']]);
    }

    private string $namaTujuan = '';

    /** @return array{status: string, gagal: int, buka_sampai: float, uji_sampai: float} */
    private static function awal(): array
    {
        return ['status' => self::CLOSED, 'gagal' => 0, 'buka_sampai' => 0.0, 'uji_sampai' => 0.0];
    }

    /**
     * Baca, ubah, dan tulis keadaan satu tujuan di bawah kunci eksklusif.
     *
     * @param callable(array): array{0: array, 1: mixed} $fn
     * @return mixed
     */
    private function ubah(string $tujuan, callable $fn)
    {
        $this->namaTujuan = $tujuan;
        $berkas = $this->folder . '/' . preg_replace('/[^A-Za-z0-9_.-]/', '_', $tujuan) . '.json';
        $fh = @fopen($berkas, 'c+');
        if ($fh === false) {
            // tanpa berkas keadaan, breaker tidak boleh menghalangi permintaan
            [, $hasil] = $fn(self::awal());
            return $hasil;
        }
        try {
            flock($fh, LOCK_EX);
            $isi = stream_get_contents($fh);
            $k   = is_string($isi) && $isi !== '' ? json_decode($isi, true) : null;
            $k   = is_array($k) ? array_merge(self::awal(), $k) : self::awal();
            [$baru, $hasil] = $fn($k);
            ftruncate($fh, 0);
            rewind($fh);
            fwrite($fh, (string) json_encode($baru));
            fflush($fh);
            return $hasil;
        } finally {
            flock($fh, LOCK_UN);
            fclose($fh);
        }
    }
}
