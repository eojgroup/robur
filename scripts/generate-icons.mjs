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
  // An opaque, anti-aliased heart-rate symbol in navy, warm beige and orange. iOS supplies
  // the rounded icon mask; retaining full square corners avoids double masks.
  const samples = [[0.25, 0.25], [0.75, 0.25], [0.25, 0.75], [0.75, 0.75]];
  const segmentDistance = (x, y, ax, ay, bx, by) => {
    const dx = bx - ax, dy = by - ay;
    const t = Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)));
    return Math.hypot(x - ax - t * dx, y - ay - t * dy);
  };
  for (let y = 0; y < height; y += 1) {
    const row = y * (width * 3 + 1);
    raw[row] = 0;
    for (let x = 0; x < width; x += 1) {
      const rgb = [0, 0, 0];
      for (const [sx, sy] of samples) {
        const u = (x + sx) / width, v = (y + sy) / height;
        const glow = Math.max(0, 1 - Math.hypot(u - 0.85, v - 0.9) / 1.3);
        const bg = [lerp(10, 22, glow), lerp(22, 43, glow), lerp(42, 67, glow)];
        const ticker = [[0.18, 0.53], [0.34, 0.53], [0.405, 0.39], [0.485, 0.695], [0.575, 0.285], [0.665, 0.53], [0.82, 0.53]];
        let outer = false, pulse = false;
        for (let part = 0; part < ticker.length - 1; part += 1) {
          const distance = segmentDistance(u, v, ...ticker[part], ...ticker[part + 1]);
          if (distance <= 0.033) {
            outer = true;
            if (part >= 1 && part <= 4) pulse = true;
          }
        }
        const ink = pulse ? [lerp(244, 232, v), lerp(145, 105, v), lerp(70, 36, v)] : outer ? [244, 234, 214] : bg;
        for (let c = 0; c < 3; c += 1) rgb[c] += ink[c] / samples.length;
      }
      const i = row + 1 + x * 3;
      raw[i] = Math.round(rgb[0]); raw[i + 1] = Math.round(rgb[1]); raw[i + 2] = Math.round(rgb[2]);
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
