<?php
declare(strict_types=1);

namespace Auth;

use PDO;

final class Db
{
    public static function connect(): PDO
    {
        $host = getenv('DB_HOST') ?: 'auth-db';
        $port = getenv('DB_PORT') ?: '3306';
        $name = getenv('DB_NAME') ?: 'auth_db';
        $user = getenv('DB_USER') ?: 'auth';
        $passwordPath = getenv('DB_PASSWORD_FILE') ?: '/run/secrets/auth_db_password';
        $password = self::readSecret($passwordPath);
        return new PDO("mysql:host={$host};port={$port};dbname={$name};charset=utf8mb4", $user, $password, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
            PDO::ATTR_TIMEOUT => 3,
        ]);
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
