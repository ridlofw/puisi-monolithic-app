import Jimp from "jimp";
import fs from "fs";
import path from "path";

export function sanitizeAndWrap(text, maxCharsPerWord = 32, maxLines = 5, maxTotal = 150) {
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

export async function renderQuote(templateName, title, quote, author, outputDir = "./latar") {
  const templatePath = path.resolve(outputDir, templateName);
  if (!fs.existsSync(templatePath)) {
    throw new Error(`Template latar tidak ditemukan: ${templateName}`);
  }

  const image = await Jimp.read(templatePath);
  const width = image.bitmap.width;
  const height = image.bitmap.height;

  // Siapkan font Jimp
  const fontTitle = await Jimp.loadFont(Jimp.FONT_SANS_32_WHITE);
  const fontBody = await Jimp.loadFont(Jimp.FONT_SANS_16_WHITE);

  // Buat lapisan overlay gelap agar teks mudah terbaca
  const overlay = new Jimp(width, height, 0x00000088);
  image.composite(overlay, 0, 0);

  const cleanTitle = (title || "Puisi").trim();
  const cleanQuote = sanitizeAndWrap(quote || "");
  const cleanAuthor = author ? `— ${author.trim()}` : "— Anonim";

  // Render teks ke gambar
  image.print(
    fontTitle,
    40,
    60,
    {
      text: cleanTitle,
      alignmentX: Jimp.HORIZONTAL_ALIGN_CENTER,
      alignmentY: Jimp.VERTICAL_ALIGN_MIDDLE,
    },
    width - 80,
    60
  );

  image.print(
    fontBody,
    50,
    140,
    {
      text: cleanQuote,
      alignmentX: Jimp.HORIZONTAL_ALIGN_CENTER,
      alignmentY: Jimp.VERTICAL_ALIGN_MIDDLE,
    },
    width - 100,
    height - 240
  );

  image.print(
    fontBody,
    40,
    height - 80,
    {
      text: cleanAuthor,
      alignmentX: Jimp.HORIZONTAL_ALIGN_RIGHT,
      alignmentY: Jimp.VERTICAL_ALIGN_BOTTOM,
    },
    width - 80,
    40
  );

  return await image.getBufferAsync(Jimp.MIME_JPEG);
}
