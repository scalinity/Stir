// image_validation_test — magic-byte sniff + mime cross-check.
//
// Covers SA1-003: client sending SVG/PDF bytes with image/png mime,
// corrupt base64, undersized/oversized inputs.

import { assertEquals } from '@std/assert';
import { decodeAndValidateImage } from '../functions/_shared/image_validation.ts';

// Minimal valid JPEG (smallest JPEG: SOI + APP0 + DQT + SOF + SOS + EOI).
// Real JPEGs are larger; tests synthesize a "plausible enough" 256-byte
// buffer that starts with FF D8 FF.
function jpegFixture(): string {
  const bytes = new Uint8Array(256);
  bytes[0] = 0xff; bytes[1] = 0xd8; bytes[2] = 0xff; bytes[3] = 0xe0;
  for (let i = 4; i < 256; i++) bytes[i] = i % 256;
  return btoa(String.fromCharCode(...bytes));
}

function pngFixture(): string {
  const bytes = new Uint8Array(256);
  const header = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  for (let i = 0; i < 8; i++) bytes[i] = header[i]!;
  for (let i = 8; i < 256; i++) bytes[i] = i % 256;
  return btoa(String.fromCharCode(...bytes));
}

function webpFixture(): string {
  const bytes = new Uint8Array(256);
  // RIFF xxxx WEBP
  bytes[0] = 0x52; bytes[1] = 0x49; bytes[2] = 0x46; bytes[3] = 0x46;
  bytes[8] = 0x57; bytes[9] = 0x45; bytes[10] = 0x42; bytes[11] = 0x50;
  for (let i = 12; i < 256; i++) bytes[i] = i % 256;
  return btoa(String.fromCharCode(...bytes));
}

function heicFixture(): string {
  const bytes = new Uint8Array(256);
  // bytes 4-7 = "ftyp", 8-11 = "heic"
  bytes[4] = 0x66; bytes[5] = 0x74; bytes[6] = 0x79; bytes[7] = 0x70;
  bytes[8] = 0x68; bytes[9] = 0x65; bytes[10] = 0x69; bytes[11] = 0x63;
  for (let i = 12; i < 256; i++) bytes[i] = i % 256;
  return btoa(String.fromCharCode(...bytes));
}

Deno.test('image-validation: JPEG bytes with image/jpeg mime → ok', () => {
  const result = decodeAndValidateImage(jpegFixture(), 'image/jpeg');
  assertEquals(result.kind, 'ok');
});

Deno.test('image-validation: PNG bytes with image/png mime → ok', () => {
  const result = decodeAndValidateImage(pngFixture(), 'image/png');
  assertEquals(result.kind, 'ok');
});

Deno.test('image-validation: WebP bytes with image/webp mime → ok', () => {
  const result = decodeAndValidateImage(webpFixture(), 'image/webp');
  assertEquals(result.kind, 'ok');
});

Deno.test('image-validation: HEIC bytes with image/heic mime → ok', () => {
  const result = decodeAndValidateImage(heicFixture(), 'image/heic');
  assertEquals(result.kind, 'ok');
});

Deno.test('image-validation: PNG bytes with image/jpeg mime → error (mismatch)', () => {
  const result = decodeAndValidateImage(pngFixture(), 'image/jpeg');
  assertEquals(result.kind, 'error');
  if (result.kind === 'error') {
    assertEquals(result.field, 'image_mime_type');
  }
});

Deno.test('image-validation: SVG (non-image bytes) with image/png mime → error', () => {
  // <?xml version="1.0"?><svg ... — no magic-byte match for PNG/JPEG/HEIC/WebP.
  const svg = '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"><text>pwned</text></svg>';
  const padded = svg + ' '.repeat(200);  // meet min-size threshold
  const base64 = btoa(padded);
  const result = decodeAndValidateImage(base64, 'image/png');
  assertEquals(result.kind, 'error');
});

Deno.test('image-validation: invalid base64 → error', () => {
  const result = decodeAndValidateImage('!!not-base64!!', 'image/jpeg');
  assertEquals(result.kind, 'error');
  if (result.kind === 'error') {
    assertEquals(result.field, 'image_base64');
  }
});

Deno.test('image-validation: too-small payload → error', () => {
  const tiny = btoa('x'.repeat(50));
  const result = decodeAndValidateImage(tiny, 'image/jpeg');
  assertEquals(result.kind, 'error');
});

Deno.test('image-validation: strips whitespace from input', () => {
  const withWhitespace = jpegFixture().replace(/(.{20})/g, '$1\n');
  const result = decodeAndValidateImage(withWhitespace, 'image/jpeg');
  assertEquals(result.kind, 'ok');
});
