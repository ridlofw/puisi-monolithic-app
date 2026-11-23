<?php
declare(strict_types=1);

namespace Pencarian\Tests;

use Pencarian\OpenSearch;
use Pencarian\Pemutus;
use Pencarian\PemutusTerbuka;
use PHPUnit\Framework\TestCase;

final class OpenSearchPemutusTest extends TestCase
{
    private string $folder;

    protected function setUp(): void
    {
        $this->folder = sys_get_temp_dir() . '/pemutus-os-' . bin2hex(random_bytes(4));
    }

    protected function tearDown(): void
    {
        foreach (glob($this->folder . '/*') ?: [] as $f) {
            @unlink($f);
        }
        @rmdir($this->folder);
    }

    public function testTigaKegagalanMembukaSirkuitLaluGagalCepat(): void
    {
        $pemutus = new Pemutus($this->folder, 3, 10.0);
        // port 1 di localhost menolak koneksi dengan segera
        $os = new OpenSearch('http://127.0.0.1:1', $pemutus);
        for ($i = 0; $i < 3; $i++) {
            try {
                $os->minta('GET', '/_cluster/health');
                self::fail('OpenSearch palsu seharusnya tidak terjangkau');
            } catch (PemutusTerbuka $e) {
                self::fail('sirkuit belum boleh terbuka pada kegagalan ke-' . ($i + 1));
            } catch (\RuntimeException) {
            }
        }
        self::assertSame(Pemutus::OPEN, $pemutus->status(OpenSearch::TUJUAN));
        $mulai = microtime(true);
        try {
            $os->minta('GET', '/_cluster/health');
            self::fail('seharusnya ditolak tanpa menyentuh jaringan');
        } catch (PemutusTerbuka) {
            self::assertLessThan(0.05, microtime(true) - $mulai);
        }
    }

    public function testTanpaPemutusTetapMencobaSetiapKali(): void
    {
        $os = new OpenSearch('http://127.0.0.1:1');
        for ($i = 0; $i < 4; $i++) {
            try {
                $os->minta('GET', '/');
            } catch (PemutusTerbuka) {
                self::fail('consumer tanpa pemutus tidak boleh gagal cepat');
            } catch (\RuntimeException) {
            }
        }
        self::assertTrue(true);
    }
}
