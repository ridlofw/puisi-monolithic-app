<?php
declare(strict_types=1);

namespace Auth;

/**
 * Closed, open, half-open breaker for auth-db (Bab 11.2). State lives in a locked temp file,
 * so every Apache process of one replica shares the same circuit.
 */
final class CircuitBreaker
{
    public const CLOSED = 'closed';
    public const OPEN = 'open';
    public const HALF_OPEN = 'half_open';

    /** @var callable(): float */
    private $clock;

    public function __construct(
        private string $directory = '',
        private int $threshold = 3,
        private float $cooldown = 10.0,
        ?callable $clock = null
    ) {
        $this->directory = $directory !== '' ? $directory : sys_get_temp_dir() . '/circuit';
        $this->clock = $clock ?? static fn (): float => microtime(true);
        if (!is_dir($this->directory)) {
            @mkdir($this->directory, 0777, true);
        }
    }

    public static function shared(): self
    {
        static $breaker = null;
        return $breaker ??= new self(
            '',
            (int) (getenv('BREAKER_THRESHOLD') ?: 3),
            (float) (getenv('BREAKER_COOLDOWN') ?: 10)
        );
    }

    public function allow(string $target): bool
    {
        return $this->update($target, function (array $s): array {
            $now = ($this->clock)();
            if ($s['state'] === self::OPEN) {
                if ($now < $s['open_until']) {
                    return [$s, false];
                }
                $s['state'] = self::HALF_OPEN;
                $s['trial_until'] = $now + $this->cooldown;
                return [$s, true];
            }
            if ($s['state'] === self::HALF_OPEN) {
                // a trial that never reported back is retired after the cooldown
                if ($now >= $s['trial_until']) {
                    $s['trial_until'] = $now + $this->cooldown;
                    return [$s, true];
                }
                return [$s, false];
            }
            return [$s, true];
        });
    }

    public function success(string $target): void
    {
        $this->update($target, static function (array $s) use ($target): array {
            if ($s['state'] !== self::CLOSED) {
                self::log('info', 'circuit breaker closed', $target);
            }
            return [self::initial(), null];
        });
    }

    public function failure(string $target): void
    {
        $this->update($target, function (array $s) use ($target): array {
            $s['failures']++;
            if ($s['state'] === self::HALF_OPEN || $s['failures'] >= $this->threshold) {
                if ($s['state'] !== self::OPEN) {
                    self::log('warning', 'circuit breaker opened', $target);
                }
                $s['state'] = self::OPEN;
                $s['open_until'] = ($this->clock)() + $this->cooldown;
            }
            return [$s, null];
        });
    }

    public function state(string $target): string
    {
        return $this->update($target, static fn (array $s): array => [$s, $s['state']]);
    }

    /** @return array{state: string, failures: int, open_until: float, trial_until: float} */
    private static function initial(): array
    {
        return ['state' => self::CLOSED, 'failures' => 0, 'open_until' => 0.0, 'trial_until' => 0.0];
    }

    private static function log(string $level, string $message, string $target): void
    {
        error_log((string) json_encode(['level' => $level, 'service' => 'auth-service', 'message' => $message,
            'target' => $target]));
    }

    /**
     * @param callable(array): array{0: array, 1: mixed} $fn
     * @return mixed
     */
    private function update(string $target, callable $fn)
    {
        $file = $this->directory . '/' . preg_replace('/[^A-Za-z0-9_.-]/', '_', $target) . '.json';
        $handle = @fopen($file, 'c+');
        if ($handle === false) {
            // without a state file the breaker must never block requests
            [, $result] = $fn(self::initial());
            return $result;
        }
        try {
            flock($handle, LOCK_EX);
            $raw = stream_get_contents($handle);
            $state = is_string($raw) && $raw !== '' ? json_decode($raw, true) : null;
            $state = is_array($state) ? array_merge(self::initial(), $state) : self::initial();
            [$next, $result] = $fn($state);
            ftruncate($handle, 0);
            rewind($handle);
            fwrite($handle, (string) json_encode($next));
            fflush($handle);
            return $result;
        } finally {
            flock($handle, LOCK_UN);
            fclose($handle);
        }
    }
}
