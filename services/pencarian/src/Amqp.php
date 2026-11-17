<?php
declare(strict_types=1);

namespace Pencarian;

use PhpAmqpLib\Channel\AMQPChannel;
use PhpAmqpLib\Connection\AMQPStreamConnection;

final class Amqp
{
    //Daftar URL node RabbitMQ, dipisah koma. Node yang mati tidak menghentikan consumer.       
    public static function daftarUrl(): array
    {
        $mentah = Konfig::env(
            'AMQP_URLS',
            'amqp://puisi:puisi@rabbitmq-1:5672/%2F,amqp://puisi:puisi@rabbitmq-2:5672/%2F,amqp://puisi:puisi@rabbitmq-3:5672/%2F'
        );
        return array_values(array_filter(array_map('trim', explode(',', $mentah)), static fn(string $s): bool => $s !== ''));
    }

    //Coba setiap node berurutan, sehingga satu node RabbitMQ yang mati tidak menghentikan consumer.
    public static function sambung(): array
    {
        $galat = null;
        foreach (self::daftarUrl() as $url) {
            $b = parse_url($url);
            if (!is_array($b) || empty($b['host'])) {
                continue;
            }
            $vhost = isset($b['path']) && ltrim((string) $b['path'], '/') !== '' ? rawurldecode(ltrim((string) $b['path'], '/')) : '/';
            try {
                $koneksi = new AMQPStreamConnection(
                    (string) $b['host'],
                    (int) ($b['port'] ?? 5672),
                    isset($b['user']) ? rawurldecode((string) $b['user']) : 'puisi',
                    isset($b['pass']) ? rawurldecode((string) $b['pass']) : 'puisi',
                    $vhost,
                    false,
                    'AMQPLAIN',
                    null,
                    'en_US',
                    3.0,
                    60.0,
                    null,
                    true,
                    25
                );
                return ['koneksi' => $koneksi, 'kanal' => $koneksi->channel(), 'node' => $b['host'] . ':' . ($b['port'] ?? 5672)];
            } catch (\Throwable $e) {
                $galat = $e;
            }
        }
        throw new \RuntimeException('Tidak ada node RabbitMQ yang terjangkau: ' . ($galat?->getMessage() ?? 'AMQP_URLS kosong'));
    }
}
