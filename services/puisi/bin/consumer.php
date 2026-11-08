<?php
declare(strict_types=1);

require_once dirname(__DIR__) . '/vendor/autoload.php';

use PhpAmqpLib\Message\AMQPMessage;
use PhpAmqpLib\Wire\AMQPTable;
use Puisi\Amqp;
use Puisi\Cache;
use Puisi\Db;
use Puisi\GabungHasil;
use Puisi\Konfig;
use Puisi\Log;
use Puisi\Metrik;
use Puisi\PuisiRepo;

putenv('NAMA_LAYANAN=poem-consumer');
$_ENV['NAMA_LAYANAN'] = 'poem-consumer';

$queue        = Konfig::env('QUEUE_HASIL', 'q.puisi-hasil');
$maksPercobaan = 3;
$headerCoba   = 'x-percobaan';

Metrik::mulaiServerDaemon('poem-consumer', $queue, (int) Konfig::env('PORT_METRIK', '9100'));
Log::info('poem-consumer dimulai', ['queue' => $queue]);

while (true) {
    $koneksi = null;
    $kanal   = null;
    try {
        $sambungan = Amqp::sambung();
        $koneksi   = $sambungan['koneksi'];
        $kanal     = $sambungan['kanal'];
        $node      = $sambungan['node'];

        $kanal->confirm_select();
        $kanal->basic_qos(0, 1, false);

        $callback = static function (AMQPMessage $pesan) use ($kanal, $queue, $maksPercobaan, $headerCoba): void {
            $mulai       = microtime(true);
            $deliveryTag = $pesan->getDeliveryTag();
            $body        = $pesan->getBody();

            $headers   = [];
            $percobaan = 1;
            if ($pesan->has('application_headers')) {
                $tabel = $pesan->get('application_headers');
                if ($tabel instanceof AMQPTable) {
                    $headers = $tabel->getNativeData();
                } elseif (is_array($tabel)) {
                    $headers = $tabel;
                }
                if (isset($headers[$headerCoba]) && is_numeric($headers[$headerCoba])) {
                    $percobaan = (int) $headers[$headerCoba];
                }
            }

            $konteks = ['percobaan' => $percobaan, 'queue' => $queue];

            try {
                $amplop = GabungHasil::validasiAmplop($body);
                $konteks['correlation_id'] = (string) $amplop['correlation_id'];
                $konteks['event_id']       = (string) $amplop['event_id'];
                $konteks['tipe']           = (string) $amplop['tipe'];
                $puisiId                   = (int) $amplop['data']['puisi_id'];
                $konteks['puisi_id']       = $puisiId;

                $ditemukan = PuisiRepo::terapkanHasilEvent($amplop);
                if (!$ditemukan) {
                    Log::peringatan('puisi_id tidak ditemukan, pesan di-ack tanpa retry', $konteks);
                } else {
                    Cache::invalidasi($puisiId);
                    Log::info('hasil analisis diterapkan', $konteks);
                }

                $kanal->basic_ack($deliveryTag);
                Metrik::catatWorker('poem-consumer', $queue, true, microtime(true) - $mulai);
            } catch (\Throwable $e) {
                Metrik::catatWorker('poem-consumer', $queue, false, microtime(true) - $mulai);
                $konteks['error'] = get_class($e) . ': ' . $e->getMessage();

                if ($percobaan >= $maksPercobaan) {
                    $kanal->basic_reject($deliveryTag, false);
                    Log::error("pesan gagal {$percobaan} kali, dipindah ke DLQ", $konteks);
                    return;
                }

                try {
                    $percobaanBerikut = $percobaan + 1;
                    $jedaDetik        = min(1 << max(0, $percobaanBerikut - 2), 4);
                    sleep($jedaDetik);

                    $headers[$headerCoba] = $percobaanBerikut;
                    $propertiBaru = [
                        'content_type'        => $pesan->has('content_type') ? $pesan->get('content_type') : 'application/json',
                        'delivery_mode'       => AMQPMessage::DELIVERY_MODE_PERSISTENT,
                        'message_id'          => $pesan->has('message_id') ? $pesan->get('message_id') : '',
                        'correlation_id'      => $pesan->has('correlation_id') ? $pesan->get('correlation_id') : '',
                        'type'                => $pesan->has('type') ? $pesan->get('type') : '',
                        'application_headers' => new AMQPTable($headers),
                    ];
                    $pesanUlang = new AMQPMessage($body, $propertiBaru);
                    $kanal->basic_publish($pesanUlang, '', $queue);
                    $kanal->wait_for_pending_acks(5.0);
                    $kanal->basic_ack($deliveryTag);
                    Log::peringatan('pesan gagal, diterbitkan ulang ke queue', $konteks);
                } catch (\Throwable $e2) {
                    $kanal->basic_nack($deliveryTag, false, true);
                    $konteks['error_ulang'] = $e2->getMessage();
                    Log::peringatan('gagal menerbitkan ulang, pesan dikembalikan ke queue', $konteks);
                }
            }
        };

        $kanal->basic_consume($queue, '', false, false, false, false, $callback);
        Log::info("terhubung ke RabbitMQ, mengonsumsi {$queue}", ['node' => $node]);

        while ($kanal->is_consuming()) {
            try {
                $kanal->wait(null, false, 20);
            } catch (\PhpAmqpLib\Exception\AMQPTimeoutException) {
                $koneksi->checkHeartBeat();
            }
        }
    } catch (\Throwable $e) {
        Db::putus();
        try {
            if ($kanal !== null) {
                $kanal->close();
            }
        } catch (\Throwable) {
        }
        try {
            if ($koneksi !== null) {
                $koneksi->close();
            }
        } catch (\Throwable) {
        }
        Log::peringatan('koneksi poem-consumer putus, mencoba lagi dalam 3 detik', [
            'error' => $e->getMessage(),
        ]);
        sleep(3);
    }
}
