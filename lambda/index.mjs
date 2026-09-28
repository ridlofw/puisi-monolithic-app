import Jimp from "jimp";
import { S3Client, GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";
import fs from "fs";
import path from "path";

// ==============================================================================
// [KONFIGURASI AWS LAMBDA]
// Bagian yang perlu Anda sesuaikan saat deploy ke AWS:
// 1. REGION: Wajib "us-east-1" (sesuai panduan Hands-on).
// 2. BUCKET_NAME: Ganti string "tim-josjis" dengan NAMA BUCKET S3 Anda yang asli.
// ==============================================================================
const REGION = process.env.AWS_REGION || "us-east-1";
const s3 = new S3Client({ region: REGION });
const BUCKET_NAME = process.env.BUCKET_NAME || "tim-josjis"; // <-- SESUAIKAN NAMA BUCKET S3 DI SINI

async function streamToBuffer(stream) {
  const chunks = [];
  for await (const chunk of stream) chunks.push(chunk);
  return Buffer.concat(chunks);
}

// Fungsi sanitasi & pemecah kata panjang agar teks rapi dan tidak tembus batas kanvas
function sanitizeAndWrap(text, maxCharsPerWord = 32, maxLines = 5, maxTotal = 150) {
  if (!text) return "";
  let clean = text.trim();

  if (clean.length > maxTotal) {
    clean = clean.substring(0, maxTotal - 3) + "...";
  }

  let lines = clean.split(/\r?\n/);
  if (lines.length > maxLines) {
    lines = lines.slice(0, maxLines);
    lines[maxLines - 1] += "...";
  }

  const processedLines = lines.map((line) => {
    const words = line.split(" ");
    const newWords = [];
    for (const w of words) {
      if (w.length <= maxCharsPerWord) {
        newWords.push(w);
      } else {
        for (let i = 0; i < w.length; i += maxCharsPerWord) {
          newWords.push(w.substring(i, i + maxCharsPerWord));
        }
      }
    }
    return newWords.join(" ");
  });

  return processedLines.join("\n");
}

// Fungsi pembantu untuk memuat gambar latar (S3 atau fallback lokal)
async function ambilTemplateBuffer(templateKey) {
  try {
    const s3Res = await s3.send(
      new GetObjectCommand({
        Bucket: BUCKET_NAME,
        Key: templateKey,
      })
    );
    return await streamToBuffer(s3Res.Body);
  } catch (err) {
    const localPaths = [
      path.resolve(templateKey),
      path.resolve("./" + templateKey),
      path.resolve("../../" + templateKey),
    ];
    for (const p of localPaths) {
      if (fs.existsSync(p)) {
        return fs.readFileSync(p);
      }
    }
    throw new Error(
      `Template '${templateKey}' tidak ditemukan di S3 maupun folder lokal. (${err.message})`
    );
  }
}

export const handler = async (event) => {
  try {
    const query = event.queryStringParameters || {};
    const action = (query.action || "preview").toLowerCase();
    const templateKey = query.template || "latar5.jpeg"; // Default latar emas seperti di gambar referensi

    // 1. Sanitasi teks input
    let rawJudul = (query.judul || "Lorem Ipsum").trim();
    const judul = sanitizeAndWrap(rawJudul, 25, 2, 50);

    let rawPenulis = (query.penulis || "").trim();
    const penulis = sanitizeAndWrap(rawPenulis, 25, 1, 35);
    const barisPenulis = penulis ? `by ${penulis}` : "";

    let rawKutipan = (
      query.kutipan ||
      query.bait ||
      query.text ||
      "Lorem ipsum dolor sit amet,\nconsectetur adipiscing elit,\nsed do eiusmod tempor incididunt ut\nlabore et dolore magna aliqua"
    ).trim();
    const kutipan = sanitizeAndWrap(rawKutipan, 32, 5, 150);

    // 2. Ambil template latar mentah
    const buffer = await ambilTemplateBuffer(templateKey);
    const image = await Jimp.read(buffer);

    // Resolusi target: 640 x 360 (Rasio 16:9)
    const W = 640;
    const H = 360;

    // ==========================================================================
    // SKALA PROPORSI EMAS (Supersampling 1.56x pada 1000 x 562)
    // Menghasilkan ukuran font optimal:
    // - Judul: ~41px (Sangat tegas, bold, berwibawa)
    // - Penulis: ~18px (Proporsional di bawah judul)
    // - Kutipan: ~20.5px (Miring halus, nyaman dibaca bahkan di thumbnail kartu)
    // ==========================================================================
    const W2 = 1000;
    const H2 = 562;
    const canvas2x = new Jimp(W2, H2, 0x00000000);

    const fontTitle64 = rawJudul.length > 25
      ? await Jimp.loadFont(Jimp.FONT_SANS_32_BLACK)
      : await Jimp.loadFont(Jimp.FONT_SANS_64_BLACK);
    const fontAuthor32 = await Jimp.loadFont(Jimp.FONT_SANS_32_BLACK);
    const fontQuote32 = await Jimp.loadFont(Jimp.FONT_SANS_32_BLACK);

    // Perhitungan tata letak optik di kanvas 1000x562
    const tinggiJudul2x = rawJudul.length > 25 ? 42 : 68;
    const gapPenulis2x = barisPenulis ? 18 : 0;
    const tinggiPenulis2x = barisPenulis ? 32 : 0;
    const gapKutipan2x = 52;
    const barisKutipanArr = kutipan.split("\n");
    const tinggiKutipan2x = barisKutipanArr.length * 44;

    const totalTinggiBlok2x = tinggiJudul2x + gapPenulis2x + tinggiPenulis2x + gapKutipan2x + tinggiKutipan2x;
    const startY2x = Math.max(65, Math.round((H2 - totalTinggiBlok2x) * 0.44));

    // a. Cetak Judul Extra Bold (3-Way Stamping)
    const judulY2x = startY2x;
    canvas2x.print(fontTitle64, -2, judulY2x, { text: judul, alignmentX: Jimp.HORIZONTAL_ALIGN_CENTER }, W2);
    canvas2x.print(fontTitle64, 2, judulY2x, { text: judul, alignmentX: Jimp.HORIZONTAL_ALIGN_CENTER }, W2);
    canvas2x.print(fontTitle64, 0, judulY2x, { text: judul, alignmentX: Jimp.HORIZONTAL_ALIGN_CENTER }, W2);

    // b. Cetak Nama Penulis tepat di bawah Judul
    let currentY2x = judulY2x + tinggiJudul2x + gapPenulis2x;
    if (barisPenulis) {
      canvas2x.print(fontAuthor32, 0, currentY2x, { text: barisPenulis, alignmentX: Jimp.HORIZONTAL_ALIGN_CENTER }, W2);
      currentY2x += tinggiPenulis2x;
    }

    // c. Render Kutipan Miring (Italic) dengan Shearing Halus
    currentY2x += gapKutipan2x;
    const qW2 = W2 - 100;
    const qH2 = Math.max(260, tinggiKutipan2x + 60);
    const quoteBuf2x = new Jimp(qW2, qH2, 0x00000000);

    quoteBuf2x.print(fontQuote32, 0, 0, {
      text: kutipan,
      alignmentX: Jimp.HORIZONTAL_ALIGN_CENTER,
    }, qW2);

    const shearFactor = 0.17; // Kemiringan italic alami
    const shearedQuote2x = new Jimp(qW2, qH2, 0x00000000);

    quoteBuf2x.scan(0, 0, qW2, qH2, function (x, y, idx) {
      const a = this.bitmap.data[idx + 3];
      if (a > 0) {
        const shiftX = Math.round((qH2 - y) * shearFactor) - Math.round(qH2 * shearFactor / 2);
        const targetX = x + shiftX;
        if (targetX >= 0 && targetX < qW2) {
          const targetIdx = (qW2 * y + targetX) << 2;
          shearedQuote2x.bitmap.data[targetIdx] = this.bitmap.data[idx];
          shearedQuote2x.bitmap.data[targetIdx + 1] = this.bitmap.data[idx + 1];
          shearedQuote2x.bitmap.data[targetIdx + 2] = this.bitmap.data[idx + 2];
          shearedQuote2x.bitmap.data[targetIdx + 3] = a;
        }
      }
    });

    // Tempelkan kutipan miring ke kanvas pembantu
    canvas2x.composite(shearedQuote2x, 50, currentY2x);

    // d. Downsample ke resolusi target 1x (640 x 360) menggunakan interpolasi Bicubic
    canvas2x.resize(W, H, Jimp.RESIZE_BICUBIC);

    // e. Gabungkan kanvas teks ke gambar latar
    image.resize(W, H);
    image.composite(canvas2x, 0, 0);

    // 6. Ekspor hasil olahan ke JPEG Buffer
    const outputBuffer = await image.getBufferAsync(Jimp.MIME_JPEG);

    // ==========================================================
    // CABANG A: ACTION = SAVE (Simpan ke S3)
    // ==========================================================
    if (action === "save") {
      const namaFile = `puisi_${Date.now()}.jpeg`;

      try {
        await s3.send(
          new PutObjectCommand({
            Bucket: BUCKET_NAME,
            Key: namaFile,
            Body: outputBuffer,
            ContentType: "image/jpeg",
          })
        );
      } catch (s3Err) {
        fs.writeFileSync(path.resolve(namaFile), outputBuffer);
        console.log(`[Lokal Fallback] Gambar disimpan di lokal: ${namaFile}`);
      }

      return {
        statusCode: 200,
        headers: {
          "content-type": "application/json",
          "access-control-allow-origin": "*",
        },
        body: JSON.stringify({
          status: "sukses",
          file_gambar: namaFile,
        }),
      };
    }

    // ==========================================================
    // CABANG B: ACTION = PREVIEW (Default, Kembalikan Gambar JPEG)
    // ==========================================================
    return {
      statusCode: 200,
      headers: {
        "content-type": "image/jpeg",
        "cache-control": "public, max-age=86400",
        "access-control-allow-origin": "*",
      },
      body: outputBuffer.toString("base64"),
      isBase64Encoded: true,
    };
  } catch (err) {
    console.error("Processing error:", err);
    return {
      statusCode: 500,
      headers: {
        "content-type": "application/json",
        "access-control-allow-origin": "*",
      },
      body: JSON.stringify({
        status: "error",
        pesan: err.message,
      }),
    };
  }
};
