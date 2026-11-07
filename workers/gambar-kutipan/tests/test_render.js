import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { sanitizeAndWrap, renderQuote } from "../render.js";

test("sanitizeAndWrap membatasi panjang baris dan total karakter", () => {
  const teksPanjang = "Kata ".repeat(40);
  const hasil = sanitizeAndWrap(teksPanjang, 32, 5, 100);
  assert.ok(hasil.length <= 103);
  assert.ok(hasil.includes("..."));
});

test("renderQuote menolak template yang tidak ada", async () => {
  await assert.rejects(
    async () => {
      await renderQuote("latar_tidak_ada.jpeg", "Judul", "Isi", "Penulis", "./latar");
    },
    {
      message: /Template latar tidak ditemukan/
    }
  );
});

test("renderQuote sukses menghasilkan buffer gambar JPEG", async () => {
  const latarAda = path.resolve("./latar/latar1.jpeg");
  if (fs.existsSync(latarAda)) {
    const buffer = await renderQuote("latar1.jpeg", "Uji Puisi", "Ini adalah teks puisi uji render.", "Tester", "./latar");
    assert.ok(Buffer.isBuffer(buffer));
    assert.ok(buffer.length > 1000);
  }
});
