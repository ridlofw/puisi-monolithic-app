<?php
declare(strict_types=1);

namespace Puisi\Tests;

use PHPUnit\Framework\TestCase;
use Puisi\Metrik;

final class MetrikDurasiTest extends TestCase
{
    public function testEmberKumulatifMulaiDariBatasPertamaYangCukup(): void
    {
        $naik = Metrik::emberDurasi('GET', '/api/puisi', 0.3);
        self::assertSame(
            ['0.5', '1', '2.5', '5', '10', '30', '+Inf', 'count'],
            array_map(static fn (string $f): string => explode('|', $f)[2], array_keys($naik))
        );
    }

    public function testRequestCepatMasukSemuaEmber(): void
    {
        self::assertCount(9 + 2, Metrik::emberDurasi('POST', '/api/puisi', 0.01));
    }

    public function testRequestSangatLambatHanyaInfDanCount(): void
    {
        self::assertSame(['POST|/api/puisi|+Inf', 'POST|/api/puisi|count'],
            array_keys(Metrik::emberDurasi('POST', '/api/puisi', 45.0)));
    }

    public function testTeksDurasiFormatPrometheus(): void
    {
        $teks = Metrik::teksDurasi([
            'GET|/api/puisi|0.05' => '3', 'GET|/api/puisi|+Inf' => '4',
            'GET|/api/puisi|count' => '4', 'GET|/api/puisi|sum' => '0.42',
        ]);
        self::assertStringContainsString('# TYPE puisi_http_durasi_detik histogram', $teks);
        self::assertStringContainsString('puisi_http_durasi_detik_bucket{method="GET",route="/api/puisi",le="0.05"} 3', $teks);
        self::assertStringContainsString('puisi_http_durasi_detik_bucket{method="GET",route="/api/puisi",le="+Inf"} 4', $teks);
        self::assertStringContainsString('puisi_http_durasi_detik_count{method="GET",route="/api/puisi"} 4', $teks);
        self::assertStringContainsString('puisi_http_durasi_detik_sum{method="GET",route="/api/puisi"} 0.42', $teks);
    }
}
