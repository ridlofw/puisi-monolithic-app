<?php
declare(strict_types=1);

namespace Puisi\Tests;

use PHPUnit\Framework\TestCase;
use Puisi\MasterRedis;

/** Node Redis atau Sentinel palsu: menjawab ROLE dan SENTINEL get-master-addr-by-name. */
final class RedisPalsu
{
    public int $role = 0;

    /** @param ?list<string> $master jawaban Sentinel */
    public function __construct(private readonly string $peran = 'master', private readonly ?array $master = null)
    {
    }

    public function rawCommand(string ...$arg): mixed
    {
        if ($arg[0] === 'ROLE') {
            $this->role++;
            return [$this->peran];
        }
        return $arg[0] === 'SENTINEL' ? $this->master : null;
    }
}

final class MasterRedisTest extends TestCase
{
    private float $waktu = 1000.0;
    private string $berkas;

    /** @var array<string, ?RedisPalsu> alamat host:port, null berarti mati */
    private array $node = [];

    /** @var list<string> alamat yang dicoba, berurutan */
    private array $dibuka = [];

    protected function setUp(): void
    {
        $this->berkas = sys_get_temp_dir() . '/master-redis-uji-' . bin2hex(random_bytes(4)) . '.json';
    }

    protected function tearDown(): void
    {
        @unlink($this->berkas);
    }

    /** @param list<string> $sentinel */
    private function penemu(array $sentinel = []): MasterRedis
    {
        return new MasterRedis(
            ['redis-1:6379', 'redis-2:6379', 'redis-3:6379'],
            $sentinel,
            'puisi',
            $this->berkas,
            function (string $host, int $port): ?object {
                $alamat = $host . ':' . $port;
                $this->dibuka[] = $alamat;
                return $this->node[$alamat] ?? null;
            },
            fn (): float => $this->waktu,
        );
    }

    public function testTanpaSentinelMemilihNodeBerperanMaster(): void
    {
        $this->node = ['redis-1:6379' => new RedisPalsu('slave'), 'redis-2:6379' => new RedisPalsu('master')];
        $hasil = $this->penemu()->cari();
        self::assertSame($this->node['redis-2:6379'], $hasil[0]);
        self::assertTrue($hasil[1]);
    }

    public function testAlamatTersimpanDipakaiTanpaRoundTripTambahan(): void
    {
        $this->node = ['redis-1:6379' => new RedisPalsu('master')];
        $this->penemu()->cari();
        $this->dibuka = [];
        $this->waktu += 4.0;
        $hasil = $this->penemu()->cari();
        self::assertSame(['redis-1:6379'], $this->dibuka, 'langsung ke master tersimpan, tanpa Sentinel');
        self::assertSame(1, $this->node['redis-1:6379']->role, 'ROLE hanya ditanya saat penemuan pertama');
        self::assertTrue($hasil[1]);
    }

    public function testAlamatKedaluwarsaDitanyakanUlangKeSentinel(): void
    {
        $this->node = [
            'sentinel-1:26379' => new RedisPalsu('sentinel', ['redis-1', '6379']),
            'redis-1:6379'     => new RedisPalsu('master'),
        ];
        $this->penemu(['sentinel-1:26379'])->cari();
        $this->dibuka = [];
        $this->waktu += 6.0;
        $this->penemu(['sentinel-1:26379'])->cari();
        self::assertSame(['sentinel-1:26379', 'redis-1:6379'], $this->dibuka);
    }

    public function testSentinelPertamaMatiSentinelKeduaMenjawab(): void
    {
        $this->node = [
            'sentinel-2:26379' => new RedisPalsu('sentinel', ['redis-3', '6379']),
            'redis-3:6379'     => new RedisPalsu('master'),
            'redis-1:6379'     => new RedisPalsu('slave'),
        ];
        $hasil = $this->penemu(['sentinel-1:26379', 'sentinel-2:26379'])->cari();
        self::assertSame($this->node['redis-3:6379'], $hasil[0]);
        self::assertSame(['sentinel-1:26379', 'sentinel-2:26379', 'redis-3:6379'], $this->dibuka);
    }

    public function testJawabanSentinelBasiDiperiksaDenganRole(): void
    {
        // Sentinel masih menyebut redis-1 padahal redis-1 sudah diturunkan; redis-2 master baru
        $this->node = [
            'sentinel-1:26379' => new RedisPalsu('sentinel', ['redis-1', '6379']),
            'redis-1:6379'     => new RedisPalsu('slave'),
            'redis-2:6379'     => new RedisPalsu('master'),
        ];
        $hasil = $this->penemu(['sentinel-1:26379'])->cari();
        self::assertSame($this->node['redis-2:6379'], $hasil[0]);
        self::assertTrue($hasil[1]);
    }

    public function testSaatPromosiReplikaDipakaiUntukMembacaSaja(): void
    {
        $this->node = ['redis-2:6379' => new RedisPalsu('slave'), 'redis-3:6379' => new RedisPalsu('slave')];
        $hasil = $this->penemu()->cari();
        self::assertSame($this->node['redis-2:6379'], $hasil[0]);
        self::assertFalse($hasil[1], 'replika bukan master');
        $this->dibuka = [];
        $this->penemu()->cari();
        self::assertNotContains('redis-1:6379', $this->dibuka, 'node mati diingat, tidak ditunggu lagi');
        self::assertContains('redis-2:6379', $this->dibuka, 'replika tidak disimpan sebagai master, jadi dicari lagi');
    }

    public function testSemuaMatiGagalTerbukaDanTidakMencobaLagiSelamaJeda(): void
    {
        $penemu = $this->penemu(['sentinel-1:26379']);
        self::assertNull($penemu->cari());
        $this->dibuka = [];
        $this->waktu += 2.0;
        self::assertNull($penemu->cari());
        self::assertSame([], $this->dibuka, 'tidak ada koneksi selama jeda');
        $this->waktu += 2.0;
        self::assertNull($penemu->cari());
        self::assertCount(4, $this->dibuka, 'setelah jeda semua dicoba lagi');
    }

    public function testPaksaMengabaikanIngatanNodeMati(): void
    {
        $penemu = $this->penemu();
        self::assertNull($penemu->cari());
        $this->node = ['redis-1:6379' => new RedisPalsu('master')];
        self::assertNull($penemu->cari());
        self::assertNotNull($penemu->cari(true));
    }

    public function testLupakanMembuatMasterDicariUlang(): void
    {
        $this->node = ['redis-1:6379' => new RedisPalsu('master')];
        $penemu = $this->penemu();
        $penemu->cari();
        $penemu->lupakan();
        $penemu->cari();
        self::assertSame(2, $this->node['redis-1:6379']->role);
    }

    public function testBerkasRusakDiabaikan(): void
    {
        file_put_contents($this->berkas, '{bukan json');
        $this->node = ['redis-1:6379' => new RedisPalsu('master')];
        self::assertTrue($this->penemu()->cari()[1]);
    }
}
