/**
 * Build-time geometry of the hero screenshot.
 *
 * The hero's glare and sheen overlays have to sit on the app window itself.
 * Measuring the current PNG keeps those overlays aligned with its rounded
 * corners and also remains safe if a future capture includes transparent edge
 * padding.
 *
 * This runs at build time only (Astro frontmatter, static output) — nothing here
 * reaches the browser.
 */

import { readFileSync } from 'node:fs';
import { inflateSync } from 'node:zlib';

export interface HeroGeometry {
  /** Intrinsic pixel size of the image — feeds the img width/height attrs. */
  width: number;
  height: number;
  /** Where the opaque window sits inside the image, as % of each edge. */
  insetLeft: number;
  insetRight: number;
  insetTop: number;
  insetBottom: number;
  /** Window corner radius as a fraction of the window's width. */
  radiusRatio: number;
}

/** Alpha above this is treated as the window surface. */
const OPAQUE = 200;

function paeth(a: number, b: number, c: number): number {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}

/** Decode an 8-bit RGBA, non-interlaced PNG to a raw pixel buffer. */
function decodeRgba(file: Buffer): { width: number; height: number; pixels: Buffer } {
  if (file.readUInt32BE(0) !== 0x89504e47) throw new Error('hero: not a PNG');

  let width = 0;
  let height = 0;
  const idat: Buffer[] = [];

  for (let i = 8; i < file.length; ) {
    const len = file.readUInt32BE(i);
    const type = file.toString('latin1', i + 4, i + 8);
    const body = file.subarray(i + 8, i + 8 + len);

    if (type === 'IHDR') {
      width = body.readUInt32BE(0);
      height = body.readUInt32BE(4);
      const depth = body[8];
      const color = body[9];
      const interlace = body[12];
      // Only the shape our screenshots actually are. Anything else would decode
      // to silently wrong geometry, so fail loudly instead.
      if (depth !== 8 || color !== 6 || interlace !== 0) {
        throw new Error(
          `hero: expected 8-bit RGBA non-interlaced PNG, got depth=${depth} colorType=${color} interlace=${interlace}`
        );
      }
    } else if (type === 'IDAT') {
      idat.push(body);
    } else if (type === 'IEND') {
      break;
    }
    i += 12 + len; // length + type + data + CRC
  }

  const raw = inflateSync(Buffer.concat(idat));
  const bpp = 4;
  const stride = width * bpp;
  const pixels = Buffer.alloc(height * stride);

  // Undo the per-scanline filter (PNG spec §9.2).
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const src = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    const cur = pixels.subarray(y * stride, (y + 1) * stride);
    const prev = y > 0 ? pixels.subarray((y - 1) * stride, y * stride) : null;

    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0;
      const b = prev ? prev[x] : 0;
      const c = prev && x >= bpp ? prev[x - bpp] : 0;
      let v = src[x];
      switch (filter) {
        case 0: break;
        case 1: v += a; break;
        case 2: v += b; break;
        case 3: v += (a + b) >> 1; break;
        case 4: v += paeth(a, b, c); break;
        default: throw new Error(`hero: bad PNG filter ${filter} on row ${y}`);
      }
      cur[x] = v & 0xff;
    }
  }

  return { width, height, pixels };
}

export function measureHero(path: string): HeroGeometry {
  const { width, height, pixels } = decodeRgba(readFileSync(path));
  const alphaAt = (x: number, y: number) => pixels[(y * width + x) * 4 + 3];

  let minX = width;
  let minY = height;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      if (alphaAt(x, y) > OPAQUE) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) throw new Error('hero: found no opaque pixels');

  // On the window's topmost row, the opaque span starts one corner-radius in.
  let firstOnTopRow = minX;
  while (firstOnTopRow <= maxX && alphaAt(firstOnTopRow, minY) <= OPAQUE) firstOnTopRow++;

  const winW = maxX - minX + 1;

  return {
    width,
    height,
    insetLeft: (minX / width) * 100,
    insetRight: ((width - 1 - maxX) / width) * 100,
    insetTop: (minY / height) * 100,
    insetBottom: ((height - 1 - maxY) / height) * 100,
    radiusRatio: (firstOnTopRow - minX) / winW,
  };
}
