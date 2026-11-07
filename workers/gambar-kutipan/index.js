import amqplib from "amqplib";
import http from "http";
import fs from "fs";
import path from "path";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { renderQuote } from "./render.js";

const AMQP_URLS = (process.env.AMQP_URLS || "amqp://puisi:puisi@rabbitmq-1:5672/%2F,amqp://puisi:puisi@rabbitmq-2:5672/%2F,amqp://puisi:puisi@rabbitmq-3:5672/%2F")
  .split(",")
  .map((u) => u.trim());

const QUEUE = "q.gambar-kutipan";
const EXCHANGE = "puisi.events";
const DLX = "puisi.dlx";
const PORT_METRIK = parseInt(process.env.PORT_METRIK || "9100", 10);
const S3_ENDPOINT = process.env.S3_ENDPOINT || "http://seaweedfs:8333";
const S3_BUCKET = process.env.S3_BUCKET || "audio";

let pesanDiproses = 0;
let pesanGagal = 0;

// Metrik HTTP Server
const serverMetrik = http.createServer((req, res) => {
  if (req.url === "/metrics") {
    const text = [
      '# HELP worker_pesan_diproses_total Pesan yang selesai diproses.',
      '# TYPE worker_pesan_diproses_total counter',
      `worker_pesan_diproses_total{worker="gambar-kutipan",queue="${QUEUE}"} ${pesanDiproses}`,
      '# HELP worker_pesan_gagal_total Percobaan yang gagal.',
      '# TYPE worker_pesan_gagal_total counter',
      `worker_pesan_gagal_total{worker="gambar-kutipan",queue="${QUEUE}"} ${pesanGagal}`,
    ].join("\n") + "\n";

    res.writeHead(200, { "Content-Type": "text/plain; version=0.0.4" });
    res.end(text);
  } else {
    res.writeHead(404);
    res.end();
  }
});

serverMetrik.listen(PORT_METRIK, "0.0.0.0", () => {
  console.log(JSON.stringify({
    level: "INFO",
    worker: "gambar-kutipan",
    pesan: `Server metrik aktif pada port ${PORT_METRIK}`
  }));
});

const s3 = new S3Client({
  endpoint: S3_ENDPOINT,
  region: "us-east-1",
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID || "test",
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY || "test",
  },
  forcePathStyle: true,
});

async function cobaSambung() {
  for (const url of AMQP_URLS) {
    try {
      const conn = await amqplib.connect(url);
      console.log(JSON.stringify({ level: "INFO", worker: "gambar-kutipan", pesan: `Terhubung ke broker: ${url}` }));
      return conn;
    } catch (e) {
      console.warn(JSON.stringify({ level: "WARN", worker: "gambar-kutipan", pesan: `Gagal menyambung ke ${url}: ${e.message}` }));
    }
  }
  return null;
}

async function jalankan() {
  while (true) {
    const conn = await cobaSambung();
    if (!conn) {
      await new Promise((r) => setTimeout(r, 3000));
      continue;
    }

    try {
      const ch = await conn.createChannel();
      await ch.prefetch(1);

      // Deklarasi quorum queue dan DLQ sesuai Bab 5.4 kontrak
      await ch.assertQueue(QUEUE, {
        durable: true,
        arguments: {
          "x-queue-type": "quorum",
          "x-delivery-limit": 3,
          "x-dead-letter-exchange": DLX,
          "x-dead-letter-routing-key": `${QUEUE}.dlq`,
        },
      });

      await ch.assertQueue(`${QUEUE}.dlq`, {
        durable: true,
        arguments: { "x-queue-type": "quorum" },
      });

      await ch.bindQueue(QUEUE, EXCHANGE, "puisi.dibuat");
      await ch.bindQueue(`${QUEUE}.dlq`, DLX, `${QUEUE}.dlq`);

      ch.consume(QUEUE, async (msg) => {
        if (!msg) return;
        const percobaan = parseInt(msg.properties.headers?.["x-percobaan"] || "1", 10);
        let event;
        try {
          event = JSON.parse(msg.content.toString("utf8"));
          const data = event.data || {};
          const puisiId = data.puisi_id;
          if (!puisiId) throw new Error("puisi_id tidak ada dalam payload event");

          const template = data.file_gambar || "latar1.jpeg";
          const bufferGambar = await renderQuote(template, data.judul, data.isi, data.penulis, "./latar");

          const namaFile = `puisi_${puisiId}.jpeg`;

          // Coba unggah ke object storage S3
          try {
            await s3.send(
              new PutObjectCommand({
                Bucket: S3_BUCKET,
                Key: `gambar/${namaFile}`,
                Body: bufferGambar,
                ContentType: "image/jpeg",
              })
            );
          } catch (errS3) {
            console.warn(JSON.stringify({
              level: "WARN",
              worker: "gambar-kutipan",
              pesan: `Gagal simpan ke S3, simpan lokal: ${errS3.message}`,
              correlation_id: event.correlation_id,
            }));
            const outDir = "./output";
            if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
            fs.writeFileSync(path.join(outDir, namaFile), bufferGambar);
          }

          // Terbitkan event puisi.dianalisis dengan sumber gambar-kutipan
          const eventHasil = {
            event_id: crypto.randomUUID(),
            tipe: "puisi.dianalisis",
            versi: 1,
            terjadi_pada: new Date().toISOString(),
            correlation_id: event.correlation_id,
            data: {
              puisi_id: puisiId,
              sumber: "gambar-kutipan",
              hasil: {
                file_gambar: namaFile,
              },
            },
          };

          ch.publish(EXCHANGE, "puisi.dianalisis", Buffer.from(JSON.stringify(eventHasil)), {
            contentType: "application/json",
            deliveryMode: 2,
            messageId: eventHasil.event_id,
            correlationId: event.correlation_id,
          });

          ch.ack(msg);
          pesanDiproses++;
          console.log(JSON.stringify({
            level: "INFO",
            worker: "gambar-kutipan",
            pesan: `Gambar kutipan puisi ${puisiId} selesai dibuat`,
            correlation_id: event.correlation_id,
          }));
        } catch (err) {
          pesanGagal++;
          console.error(JSON.stringify({
            level: "ERROR",
            worker: "gambar-kutipan",
            pesan: `Gagal memproses pesan: ${err.message}`,
            percobaan: percobaan,
          }));

          if (percobaan >= 3) {
            ch.reject(msg, false);
          } else {
            const headers = { ...(msg.properties.headers || {}), "x-percobaan": percobaan + 1 };
            ch.publish("", QUEUE, msg.content, {
              ...msg.properties,
              headers,
            });
            ch.ack(msg);
          }
        }
      });

      console.log(JSON.stringify({ level: "INFO", worker: "gambar-kutipan", pesan: `Mengonsumsi antrean ${QUEUE}` }));

      await new Promise((resolve, reject) => {
        conn.on("close", resolve);
        conn.on("error", reject);
      });
    } catch (e) {
      console.warn(JSON.stringify({ level: "WARN", worker: "gambar-kutipan", pesan: `Koneksi putus: ${e.message}` }));
      await new Promise((r) => setTimeout(r, 3000));
    }
  }
}

jalankan().catch(console.error);
