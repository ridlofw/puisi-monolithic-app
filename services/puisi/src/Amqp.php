<?php
declare(strict_types=1);

namespace Puisi;

use PhpAmqpLib\Channel\AMQPChannel;
use PhpAmqpLib\Connection\AMQPStreamConnection;
use PhpAmqpLib\Message\AMQPMessage;
use PhpAmqpLib\Wire\AMQPTable;

final class Amqp
{
    public const EXCHANGE = 'puisi.events';

    /**
     * Coba sambung ke daftar AMQP_URLS secara berurutan (failover antar-node RabbitMQ).
     *
     * @return array{koneksi: AMQPStreamConnection, kanal: AMQPChannel, node: string}
     */
    public static function sambung(): array
    {
        $galatTerakhir = null;
        foreach (Konfig::daftarUrlAmqp() as $url) {
            $bagian = parse_url($url);
            if (!is_array($bagian) || empty($bagian['host'])) {
                continue;
            }
            $host  = (string) $bagian['host'];
            $port  = isset($bagian['port']) ? (int) $bagian['port'] : 5672;
            $user  = isset($bagian['user']) ? rawurldecode((string) $bagian['user']) : 'puisi';
            $pass  = isset($bagian['pass']) ? rawurldecode((string) $bagian['pass']) : 'puisi';
            $vhost = '/';
            if (isset($bagian['path']) && $bagian['path'] !== '') {
                $jalur = ltrim((string) $bagian['path'], '/');
                $vhost = $jalur !== '' ? rawurldecode($jalur) : '/';
            }

            try {
                $koneksi = new AMQPStreamConnection(
                    $host,
                    $port,
                    $user,
                    $pass,
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
                $kanal = $koneksi->channel();
                return [
                    'koneksi' => $koneksi,
                    'kanal'   => $kanal,
                    'node'    => "{$host}:{$port}",
                ];
            } catch (\Throwable $e) {
                $galatTerakhir = $e;
            }
        }

        throw new \RuntimeException(
            'Tidak ada node RabbitMQ yang terjangkau: '
            . ($galatTerakhir ? $galatTerakhir->getMessage() : 'AMQP_URLS kosong')
        );
    }

    /**
     * Terbitkan event ke exchange puisi.events dengan publisher confirm.
     *
     * @param array<string, mixed> $headers
     */
    public static function terbitkan(
        AMQPChannel $kanal,
        string $routingKey,
        string $payloadJson,
        string $eventId,
        string $correlationId,
        array $headers = [],
        string $exchange = self::EXCHANGE
    ): void {
        $properti = [
            'content_type'   => 'application/json',
            'delivery_mode'  => AMQPMessage::DELIVERY_MODE_PERSISTENT,
            'message_id'     => $eventId,
            'correlation_id' => $correlationId,
            'type'           => $routingKey,
        ];
        if ($headers !== []) {
            $properti['application_headers'] = new AMQPTable($headers);
        }

        $pesan = new AMQPMessage($payloadJson, $properti);
        $kanal->basic_publish($pesan, $exchange, $routingKey);
        $kanal->wait_for_pending_acks(5.0);
    }
}

