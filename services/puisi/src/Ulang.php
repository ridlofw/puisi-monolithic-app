<?php
declare(strict_types=1);

namespace Puisi;

/**
 * Jeda sebelum percobaan ulang consumer: backoff eksponensial 1 s, 2 s, maksimal 4 s,
 * ditambah jitter 20 persen agar retry massal tidak serentak.
 */
final class Ulang
{
    public const JITTER = 0.2;

    /**
     * @param int           $percobaan percobaan berikutnya, dimulai dari 2
     * @param callable|null $acak      fungsi (min, max) -> float, untuk tes
     * @return int jeda dalam mikrodetik
     */
    public static function jedaMikro(int $percobaan, ?callable $acak = null): int
    {
        $dasar = min(1 << max($percobaan - 2, 0), 4);
        $acak  ??= static fn (float $min, float $maks): float => $min + (mt_rand() / mt_getrandmax()) * ($maks - $min);
        $faktor = $acak(1 - self::JITTER, 1 + self::JITTER);

        return (int) round($dasar * $faktor * 1_000_000);
    }
}
