<?php
declare(strict_types=1);

//Consumer q.pencarian-indeks. Aturan ulang mengikuti: 
//gagal pada percobaan 1 atau 2 -> terbitkan ulang ke queue yang sama dengan x-percobaan naik, lalu ack;
//gagal pada percobaan 3 -> reject tanpa requeue, dead letter exchange memindahkannya ke DLQ.
require_once dirname(__DIR__) . '/vendor/autoload.php';

use Pencarian\Amqp;
use Pencarian\Konfig;
use Pencarian\Log;
use Pencarian\OpenSearch;
use Pencarian\Penangan;
use PhpAmqpLib\Exception\AMQPTimeoutException;
use PhpAmqpLib\Message\AMQPMessage;
use PhpAmqpLib\Wire\AMQPTable;

putenv('NAMA_LAYANAN=search-consumer');

const MAKS_PERCOBAAN = 3;
const HEADER_PERCOBAAN = 'x-percobaan';

$queue = Konfig::env('QUEUE', 'q.pencarian-indeks');
$os    = new OpenSearch();
Log::info('search-consumer dimulai', ['queue' => $queue]);

while (true) {
    $koneksi = null;
    $kanal   = null;
    try {
        ['koneksi' => $koneksi, 'kanal' => $kanal, 'node' => $node] = Amqp::sambung();
        $kanal->confirm_select();
        $kanal->basic_qos(0, 1, false);

        $callback = static function (AMQPMessage $pesan) use ($kanal, $queue, $os): void {
            $tag     = $pesan->getDeliveryTag();
            $body    = $pesan->getBody();
            $headers = [];
            if ($pesan->has('application_headers')) {
                $tabel   = $pesan->get('application_headers');
                $headers = $tabel instanceof AMQPTable ? $tabel->getNativeData() : (is_array($tabel) ? $tabel : []);
            }
            $percobaan = isset($headers[HEADER_PERCOBAAN]) && is_numeric($headers[HEADER_PERCOBAAN])
                ? (int) $headers[HEADER_PERCOBAAN] : 1;
            $konteks = ['percobaan' => $percobaan, 'queue' => $queue];

            try {
                $amplop = Penangan::bacaAmplop($body);
                $konteks += [
                    'correlation_id' => $amplop['correlation_id'],
                    'event_id'       => $amplop['event_id'],
                    'tipe'           => $amplop['tipe'],
                    'puisi_id'       => $amplop['data']['puisi_id'],
                ];
                $berubah = Penangan::terapkan($amplop, $os);
                $kanal->basic_ack($tag);
                Log::info($berubah ? 'indeks diperbarui' : 'event tidak mengubah indeks', $konteks);
            } catch (\Throwable $e) {
                $konteks['error'] = get_class($e) . ': ' . $e->getMessage();
                if ($percobaan >= MAKS_PERCOBAAN) {
                    $kanal->basic_reject($tag, false);
                    Log::error("pesan gagal {$percobaan} kali, dipindah ke DLQ", $konteks);
                    return;
                }
                try {
                    $berikut = $percobaan + 1;
                    sleep(min(1 << max(0, $berikut - 2), 4));
                    $headers[HEADER_PERCOBAAN] = $berikut;
                    $kanal->basic_publish(new AMQPMessage($body, [
                        'content_type'        => 'application/json',
                        'delivery_mode'       => AMQPMessage::DELIVERY_MODE_PERSISTENT,
                        'message_id'          => $pesan->has('message_id') ? $pesan->get('message_id') : '',
                        'correlation_id'      => $pesan->has('correlation_id') ? $pesan->get('correlation_id') : '',
                        'type'                => $pesan->has('type') ? $pesan->get('type') : '',
                        'application_headers' => new AMQPTable($headers),
                    ]), '', $queue);
                    $kanal->wait_for_pending_acks(5.0);
                    $kanal->basic_ack($tag);
                    Log::peringatan('pesan gagal, diterbitkan ulang ke queue', $konteks);
                } catch (\Throwable $e2) {
                    $kanal->basic_nack($tag, false, true);
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
            } catch (AMQPTimeoutException) {
                $koneksi->checkHeartBeat();
            }
        }
    } catch (\Throwable $e) {
        foreach ([$kanal, $koneksi] as $x) {
            try {
                $x?->close();
            } catch (\Throwable) {
            }
        }
        Log::peringatan('koneksi putus, mencoba lagi dalam 3 detik', ['error' => $e->getMessage()]);
        sleep(3);
    }
}
