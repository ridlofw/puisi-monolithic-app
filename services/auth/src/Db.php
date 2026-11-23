<?php
declare(strict_types=1);

namespace Auth;

use PDO;

final class Db
{
    public const TARGET = 'auth-db';

    /**
     * Persistent connection guarded by the circuit breaker. While the breaker is open the call
     * fails immediately instead of waiting for a dead database.
     */
    public static function connect(?CircuitBreaker $breaker = null): PDO
    {
        $breaker ??= CircuitBreaker::shared();
        if (!$breaker->allow(self::TARGET)) {
            throw new DbUnavailable('auth-db circuit is open, failing fast.');
        }
        $host = getenv('DB_HOST') ?: 'auth-db';
        $port = getenv('DB_PORT') ?: '3306';
        $name = getenv('DB_NAME') ?: 'auth_db';
        $user = getenv('DB_USER') ?: 'auth';
        $passwordPath = getenv('DB_PASSWORD_FILE') ?: '/run/secrets/auth_db_password';
        $password = self::readSecret($passwordPath);
        // ATTR_TIMEOUT only bounds the connect; a frozen server accepts TCP but never greets
        ini_set('mysqlnd.net_read_timeout', getenv('DB_READ_TIMEOUT') ?: '3');
        try {
            $pdo = new PDO("mysql:host={$host};port={$port};dbname={$name};charset=utf8mb4", $user, $password, [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES => false,
                PDO::ATTR_TIMEOUT => 3,
                PDO::ATTR_PERSISTENT => (getenv('DB_PERSISTENT') ?: '1') === '1',
            ]);
            $pdo->query('SELECT 1');
        } catch (\PDOException $e) {
            $breaker->failure(self::TARGET);
            throw $e;
        }
        $breaker->success(self::TARGET);
        return $pdo;
    }

    public static function readSecret(string $path): string
    {
        $secret = @file_get_contents($path);
        if ($secret === false || trim($secret) === '') {
            throw new \RuntimeException('Required secret is unavailable.');
        }
        return trim($secret);
    }
}
