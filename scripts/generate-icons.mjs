import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { deflateSync } from "node:zlib";

const root = process.cwd();
const iconDir = join(root, "apps/mobile/ios/Resources/Assets.xcassets/AppIcon.appiconset");
const webDir = join(root, "apps/web/public");

const icons = [
  ["Icon-20@1x.png", 20],
  ["Icon-20@2x.png", 40],
  ["Icon-20@3x.png", 60],
  ["Icon-29@1x.png", 29],
  ["Icon-29@2x.png", 58],
  ["Icon-29@3x.png", 87],
  ["Icon-40@1x.png", 40],
  ["Icon-40@2x.png", 80],
  ["Icon-40@3x.png", 120],
  ["Icon-60@2x.png", 120],
  ["Icon-60@3x.png", 180],
  ["Icon-76@1x.png", 76],
  ["Icon-76@2x.png", 152],
  ["Icon-83.5@2x.png", 167],
  ["Icon-1024.png", 1024],
  ["Icon-watch-48.png", 48],
  ["Icon-watch-55.png", 55],
  ["Icon-watch-58.png", 58],
  ["Icon-watch-87.png", 87],
  ["Icon-watch-80.png", 80],
  ["Icon-watch-88.png", 88],
  ["Icon-watch-100.png", 100],
  ["Icon-watch-172.png", 172],
  ["Icon-watch-196.png", 196],
  ["Icon-watch-216.png", 216]
];

const crcTable = new Uint32Array(256);
for (let n = 0; n < 256; n += 1) {
  let c = n;
  for (let k = 0; k < 8; k += 1) {
    c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  }
  crcTable[n] = c >>> 0;
}

function crc32(buffer) {
  let c = 0xffffffff;
  for (const byte of buffer) {
    c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const typeBuffer = Buffer.from(type);
  const length = Buffer.alloc(4);
  const crc = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuffer, data])), 0);
  return Buffer.concat([length, typeBuffer, data, crc]);
}

function lerp(a, b, t) {
  return Math.round(a + (b - a) * t);
}

function png(width, height) {
  const raw = Buffer.alloc((width * 3 + 1) * height);
  const cx = width * 0.5;
  const cy = height * 0.5;
  const radius = width * 0.3;

  for (let y = 0; y < height; y += 1) {
    const row = y * (width * 3 + 1);
    raw[row] = 0;

    for (let x = 0; x < width; x += 1) {
      const t = (x + y) / (width + height);
      const dx = x - cx;
      const dy = y - cy;
      const dist = Math.sqrt(dx * dx + dy * dy);
      const band = Math.abs(dist - radius) < width * 0.035;
      const bar = Math.abs(x - cx) < width * 0.045 || Math.abs(y - cy) < height * 0.045;
      const i = row + 1 + x * 3;

      const bg = [
        lerp(18, 38, t),
        lerp(42, 76, t),
        lerp(47, 78, t)
      ];
      const mark = band || bar ? [75, 211, 149] : bg;
      const accent = dist < width * 0.08 ? [255, 111, 97] : mark;

      raw[i] = accent[0];
      raw[i + 1] = accent[1];
      raw[i + 2] = accent[2];
    }
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  // App Store icons must not contain an alpha channel, even if fully opaque.
  ihdr[9] = 2;
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0))
  ]);
}

function writePng(path, size) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, png(size, size));
}

for (const [name, size] of icons) {
  writePng(join(iconDir, name), size);
}

writePng(join(webDir, "favicon.png"), 64);
writePng(join(webDir, "apple-touch-icon.png"), 180);

console.log(`Generated ${icons.length + 2} Robur icons.`);
