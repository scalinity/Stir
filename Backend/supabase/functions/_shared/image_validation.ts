// Image bytes validation — decode base64 + magic-byte sniff.
//
// Prevents mime-type/bytes mismatch (SA1-003): a client claiming
// image_mime_type="image/png" but sending SVG, PDF, or arbitrary bytes
// reaches Gemini and could exploit the multimodal OCR for prompt
// injection, waste Gemini quota on broken inputs, or trigger opaque 400s.
//
// Hard size cap: 6 MiB decoded (roughly matches Supabase Edge Function
// gateway body limit — anything larger is rejected at the platform layer
// anyway). Minimum 100 bytes — below that is provably not a real image.
//
// Magic-byte signatures:
//   JPEG: FF D8 FF
//   PNG:  89 50 4E 47 0D 0A 1A 0A
//   HEIC: bytes 4–11 spell "ftyp<brand>" where brand ∈
//         {heic, heix, hevc, hevx, mif1, msf1, heim, heis}
//   WebP: RIFF....WEBP (bytes 0–3 = "RIFF", 8–11 = "WEBP")

export type SupportedMime =
  | 'image/jpeg'
  | 'image/png'
  | 'image/heic'
  | 'image/webp';

export type ImageValidationResult =
  | { kind: 'ok'; bytes: Uint8Array; mime: SupportedMime }
  | { kind: 'error'; field: 'image_base64' | 'image_mime_type'; reason: string };

const MAX_DECODED_BYTES = 6 * 1024 * 1024;
const MIN_DECODED_BYTES = 100;

export function decodeAndValidateImage(
  base64: string,
  claimedMime: SupportedMime,
): ImageValidationResult {
  // 1. base64 decode (atob tolerates no padding differences; we strip
  //    whitespace/newlines that sometimes sneak in from buggy clients).
  const stripped = base64.replace(/\s+/g, '');
  let bytes: Uint8Array;
  try {
    const bin = atob(stripped);
    bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  } catch {
    return { kind: 'error', field: 'image_base64', reason: 'Not valid base64.' };
  }

  // 2. Size bounds.
  if (bytes.length < MIN_DECODED_BYTES) {
    return { kind: 'error', field: 'image_base64', reason: 'Image too small.' };
  }
  if (bytes.length > MAX_DECODED_BYTES) {
    return { kind: 'error', field: 'image_base64', reason: 'Image too large (max 6 MiB decoded).' };
  }

  // 3. Magic-byte sniff.
  const actualMime = detectMime(bytes);
  if (!actualMime) {
    return { kind: 'error', field: 'image_base64', reason: 'Unrecognized image format.' };
  }

  // 4. Mime/bytes consistency. Tolerate HEIC brand variants as a single
  //    logical mime ("image/heic" covers heix/hevc/hevx/mif1/msf1/heim/heis).
  if (actualMime !== claimedMime) {
    return {
      kind: 'error',
      field: 'image_mime_type',
      reason: `Image bytes are ${actualMime} but image_mime_type is ${claimedMime}.`,
    };
  }

  return { kind: 'ok', bytes, mime: actualMime };
}

function detectMime(bytes: Uint8Array): SupportedMime | null {
  if (bytes.length < 12) return null;

  // JPEG: FF D8 FF
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';

  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (
    bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 &&
    bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a
  ) return 'image/png';

  // WebP: bytes 0..3 = "RIFF", 8..11 = "WEBP"
  if (
    bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
    bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50
  ) return 'image/webp';

  // HEIC: bytes 4..7 = "ftyp", bytes 8..11 = brand code.
  if (
    bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 && bytes[7] === 0x70
  ) {
    const brand = String.fromCharCode(bytes[8]!, bytes[9]!, bytes[10]!, bytes[11]!);
    const heicBrands = new Set(['heic', 'heix', 'hevc', 'hevx', 'mif1', 'msf1', 'heim', 'heis']);
    if (heicBrands.has(brand)) return 'image/heic';
  }

  return null;
}
