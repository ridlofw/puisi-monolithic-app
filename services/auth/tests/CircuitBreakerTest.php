<?php
declare(strict_types=1);

use Auth\CircuitBreaker;
use Auth\Db;
use Auth\DbUnavailable;
use PHPUnit\Framework\TestCase;

final class CircuitBreakerTest extends TestCase
{
    private float $now = 500.0;
    private string $directory;

    protected function setUp(): void
    {
        $this->directory = sys_get_temp_dir() . '/circuit-test-' . bin2hex(random_bytes(4));
    }

    protected function tearDown(): void
    {
        foreach (glob($this->directory . '/*') ?: [] as $file) {
            @unlink($file);
        }
        @rmdir($this->directory);
    }

    private function breaker(): CircuitBreaker
    {
        return new CircuitBreaker($this->directory, 3, 10.0, fn (): float => $this->now);
    }

    public function testOpensAfterThreeConsecutiveFailures(): void
    {
        $b = $this->breaker();
        $b->failure('auth-db');
        $b->failure('auth-db');
        $this->assertTrue($b->allow('auth-db'));
        $b->failure('auth-db');
        $this->assertSame(CircuitBreaker::OPEN, $b->state('auth-db'));
        $this->assertFalse($b->allow('auth-db'));
    }

    public function testHalfOpenAllowsOneTrialThenClosesOnSuccess(): void
    {
        $b = $this->breaker();
        for ($i = 0; $i < 3; $i++) {
            $b->failure('auth-db');
        }
        $this->now += 10.1;
        $this->assertTrue($b->allow('auth-db'));
        $this->assertFalse($b->allow('auth-db'));
        $b->success('auth-db');
        $this->assertSame(CircuitBreaker::CLOSED, $b->state('auth-db'));
    }

    public function testHalfOpenFailureReopens(): void
    {
        $b = $this->breaker();
        for ($i = 0; $i < 3; $i++) {
            $b->failure('auth-db');
        }
        $this->now += 11;
        $b->allow('auth-db');
        $b->failure('auth-db');
        $this->assertFalse($b->allow('auth-db'));
    }

    public function testConnectFailsFastWithoutNetworkWhileOpen(): void
    {
        $b = $this->breaker();
        for ($i = 0; $i < 3; $i++) {
            $b->failure(Db::TARGET);
        }
        $start = microtime(true);
        try {
            Db::connect($b);
            $this->fail('connect must not be attempted while the circuit is open');
        } catch (DbUnavailable) {
            $this->assertLessThan(0.05, microtime(true) - $start);
        }
    }
}
