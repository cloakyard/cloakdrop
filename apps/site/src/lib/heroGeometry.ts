import { readFileSync } from 'node:fs';

/** Read a PNG's intrinsic size from its IHDR chunk at build time. */
export function readPngDimensions(path: string): { width: number; height: number } {
  const header = readFileSync(path).subarray(0, 24);
  const hasPngSignature = header.length === 24 && header.readUInt32BE(0) === 0x8950_4e47;
  if (!hasPngSignature || header.toString('ascii', 12, 16) !== 'IHDR') {
    throw new Error(`Expected a PNG hero image at ${path}`);
  }
  return { width: header.readUInt32BE(16), height: header.readUInt32BE(20) };
}
