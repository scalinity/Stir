// Recipe URL fetches connect only to a validated public IP. The original
// hostname is retained for HTTP Host, TLS SNI, and certificate verification.
import { isIP } from 'node:net';

export class FetchFailure extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'FetchFailure';
  }
}

const MAX_BYTES = 2 * 1024 * 1024;
const TIMEOUT_MS = 10_000;
const MAX_REDIRECTS = 5;

function bareHost(value: string): string {
  return value.startsWith('[') && value.endsWith(']') ? value.slice(1, -1) : value;
}

/** Unrecognized and non-global addresses fail closed, including mapped IPv4. */
export function isPublicAddress(value: string): boolean {
  const address = bareHost(value).toLowerCase();
  const family = isIP(address);
  if (family === 4) {
    const [a = 0, b = 0, c = 0] = address.split('.').map(Number);
    return !(a === 0 || a === 10 || a === 127 || a >= 224 ||
      (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) ||
      (a === 192 && b === 0 && (c === 0 || c === 2)) ||
      (a === 192 && b === 88 && c === 99) ||
      (a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) ||
      (a === 203 && b === 0 && c === 113));
  }
  if (family !== 6 || address.includes('%')) return false;
  // URL normalizes embedded dotted IPv4 into hex groups; expand :: before
  // classifying so every spelling has the same result.
  const normalized = new URL('http://[' + address + ']/').hostname.slice(1, -1);
  const halves = normalized.split('::');
  const left = (halves[0] ?? '').split(':').filter(Boolean);
  const right = (halves[1] ?? '').split(':').filter(Boolean);
  const groups = halves.length === 2
    ? [...left, ...Array<string>(8 - left.length - right.length).fill('0'), ...right]
    : left;
  const words = groups.map((part) => parseInt(part, 16));
  if (words.length !== 8) return false;
  if (words.slice(0, 5).every((word) => word === 0) && words[5] === 0xffff) {
    const high = words[6] ?? 0;
    const low = words[7] ?? 0;
    return isPublicAddress([high >> 8, high & 255, low >> 8, low & 255].join('.'));
  }
  // Global-unicast only. Exclude documentation and transition/translation
  // ranges rather than letting an embedded private IPv4 escape classification.
  const first = words[0] ?? 0;
  const second = words[1] ?? 0;
  if ((first & 0xe000) !== 0x2000) return false;
  if (first === 0x2002) return false; // 6to4
  if (first === 0x2001 && (second < 0x200 || second === 0xdb8)) return false;
  if (first === 0x3fff && (second & 0xf000) === 0) return false; // documentation
  return true;
}

export async function resolvePublicAddresses(url: URL): Promise<string[]> {
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new FetchFailure('Only http and https recipe links are supported.');
  }
  if (url.username || url.password) throw new FetchFailure('URL credentials are not supported.');
  const hostname = bareHost(url.hostname);
  let addresses: string[];
  if (isIP(hostname)) {
    addresses = [hostname];
  } else {
    const records = await Promise.allSettled([
      Deno.resolveDns(hostname, 'A'),
      Deno.resolveDns(hostname, 'AAAA'),
    ]);
    addresses = records.flatMap((result) => result.status === 'fulfilled' ? result.value : []);
  }
  if (addresses.length === 0 || addresses.some((address) => !isPublicAddress(address))) {
    throw new FetchFailure('The recipe link must resolve to a public address.');
  }
  return [...new Set(addresses)];
}

export function pinnedDestination(url: URL, address: string) {
  if (!isIP(address)) throw new FetchFailure('Recipe destination is not an IP address.');
  return {
    hostname: address,
    port: Number(url.port || (url.protocol === 'https:' ? 443 : 80)),
    tlsHostname: bareHost(url.hostname),
    host: url.host,
  };
}

interface FetchedPage {
  status: number;
  location: string | undefined;
  text: string;
}

/** Use the validated IP for TCP and the original hostname for TLS verification.
 * Edge Runtime's node:https compatibility layer ignores servername when it
 * converts a request to fetch(https://IP), so it cannot enforce both identities.
 * Native startTls upgrades this exact socket without another DNS lookup. */
export async function requestPinned(
  url: URL,
  address: string,
  signal: AbortSignal,
): Promise<FetchedPage> {
  const destination = pinnedDestination(url, address);
  let connection: Deno.Conn | undefined;
  const close = () => {
    try {
      connection?.close();
    } catch { /* already closed */ }
  };
  const aborted = new Promise<never>((_, reject) => {
    const abort = () => {
      close();
      reject(new FetchFailure('Recipe link timed out.'));
    };
    if (signal.aborted) abort();
    else signal.addEventListener('abort', abort, { once: true });
  });
  const work = async (): Promise<FetchedPage> => {
    const tcp = await Deno.connect({ hostname: destination.hostname, port: destination.port });
    connection = tcp;
    if (signal.aborted) {
      close();
      throw new FetchFailure('Recipe link timed out.');
    }
    if (url.protocol === 'https:') {
      connection = await Deno.startTls(tcp, {
        hostname: destination.tlsHostname,
        alpnProtocols: ['http/1.1'],
      });
    }
    if (signal.aborted) {
      close();
      throw new FetchFailure('Recipe link timed out.');
    }
    const request = new TextEncoder().encode(
      `GET ${url.pathname}${url.search} HTTP/1.1\r\nHost: ${destination.host}\r\n` +
        'User-Agent: StirBot/1.0 (+https://getstir.app)\r\nAccept: text/html,application/json;q=0.9,*/*;q=0.8\r\n' +
        'Accept-Encoding: gzip, deflate\r\nConnection: close\r\n\r\n',
    );
    let written = 0;
    while (written < request.length) written += await connection.write(request.subarray(written));
    // Bound the wire response, including HTTP framing, before allocating it.
    const chunks: Uint8Array[] = [];
    let length = 0;
    while (true) {
      const buffer = new Uint8Array(16_384);
      const count = await connection.read(buffer);
      if (count === null) break;
      length += count;
      if (length > MAX_BYTES + 65_536) throw new FetchFailure('Recipe response exceeds 2 MiB.');
      chunks.push(buffer.slice(0, count));
    }
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    // RFC 9110 permits one or more interim 1xx blocks before the final
    // response. Bound their combined headers with the existing 16 KiB cap.
    let headStart = 0;
    let headEnd: number;
    let status: number;
    let headers: Headers;
    while (true) {
      headEnd = findCRLF(bytes, headStart, true);
      if (headEnd < 0 || headEnd + 4 > 16_384) {
        throw new FetchFailure('Invalid recipe response headers.');
      }
      const lines = new TextDecoder().decode(bytes.subarray(headStart, headEnd)).split('\r\n');
      status = Number(lines.shift()?.match(/^HTTP\/1\.[01] (\d{3})(?: |$)/)?.[1]);
      if (status < 100 || status > 599 || !status) {
        throw new FetchFailure('Invalid recipe response status.');
      }
      headers = new Headers();
      for (const line of lines) {
        const colon = line.indexOf(':');
        if (colon < 1) throw new FetchFailure('Invalid recipe response header.');
        headers.append(line.slice(0, colon), line.slice(colon + 1).trim());
      }
      if (status >= 200) break;
      if (status === 101) throw new FetchFailure('Recipe protocol upgrades are not supported.');
      headStart = headEnd + 4;
    }
    if (status >= 300 && status < 400) {
      return { status, location: headers.get('location') ?? undefined, text: '' };
    }
    if (status < 200 || status >= 300) {
      throw new FetchFailure('Recipe site returned HTTP ' + status);
    }
    if (!/text\/|json|xml/i.test(headers.get('content-type') ?? '')) {
      throw new FetchFailure('Recipe site did not return text.');
    }
    let body = bytes.subarray(headEnd + 4);
    const transfer = headers.get('transfer-encoding');
    if (transfer) {
      if (transfer.toLowerCase() !== 'chunked') {
        throw new FetchFailure('Unsupported recipe transfer encoding.');
      }
      body = decodeChunks(body);
    } else if (
      headers.has('content-length') && Number(headers.get('content-length')) !== body.length
    ) {
      throw new FetchFailure('Incomplete recipe response.');
    }
    const encoding = headers.get('content-encoding');
    let stream = new Blob([body]).stream();
    if (encoding && encoding !== 'identity') {
      if (encoding !== 'gzip' && encoding !== 'deflate') {
        throw new FetchFailure('Unsupported recipe response encoding.');
      }
      stream = stream.pipeThrough(new DecompressionStream(encoding));
    }
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    let total = 0;
    let text = '';
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        total += value.length;
        if (total > MAX_BYTES) throw new FetchFailure('Recipe response exceeds 2 MiB.');
        text += decoder.decode(value, { stream: true });
      }
      return { status, location: undefined, text: text + decoder.decode() };
    } finally {
      await reader.cancel();
    }
  };
  try {
    return await Promise.race([work(), aborted]);
  } finally {
    close();
  }
}

function findCRLF(bytes: Uint8Array, offset: number, double = false): number {
  for (let i = offset; i < bytes.length - (double ? 3 : 1); i++) {
    if (
      bytes[i] === 13 && bytes[i + 1] === 10 &&
      (!double || (bytes[i + 2] === 13 && bytes[i + 3] === 10))
    ) return i;
  }
  return -1;
}

function decodeChunks(bytes: Uint8Array): Uint8Array<ArrayBuffer> {
  const chunks: Uint8Array[] = [];
  let cursor = 0;
  let total = 0;
  while (cursor < bytes.length) {
    const end = findCRLF(bytes, cursor);
    if (end < 0 || end - cursor > 1024) throw new FetchFailure('Invalid recipe chunk.');
    const sizeText = new TextDecoder().decode(bytes.subarray(cursor, end)).split(';')[0] ?? '';
    if (!/^[0-9a-f]+$/i.test(sizeText)) throw new FetchFailure('Invalid recipe chunk size.');
    const size = parseInt(sizeText, 16);
    if (size === 0) {
      const body = new Uint8Array(total);
      let offset = 0;
      for (const chunk of chunks) {
        body.set(chunk, offset);
        offset += chunk.length;
      }
      return body;
    }
    total += size;
    if (
      total > MAX_BYTES || end + 2 + size + 2 > bytes.length || bytes[end + 2 + size] !== 13 ||
      bytes[end + 3 + size] !== 10
    ) {
      throw new FetchFailure('Invalid or oversized recipe chunk.');
    }
    chunks.push(bytes.subarray(end + 2, end + 2 + size));
    cursor = end + 2 + size + 2;
  }
  throw new FetchFailure('Incomplete recipe chunked response.');
}

/** The only production caller: validation and connection use the same IP. */
export async function fetchPublicRecipeText(
  raw: string,
  dependencies = { resolve: resolvePublicAddresses, request: requestPinned },
): Promise<string> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    let url = new URL(raw);
    for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
      const addresses = await Promise.race([
        dependencies.resolve(url),
        new Promise<never>((_, reject) => {
          if (controller.signal.aborted) reject(new FetchFailure('Recipe link timed out.'));
          else {controller.signal.addEventListener('abort', () =>
              reject(new FetchFailure('Recipe link timed out.')), { once: true });}
        }),
      ]);
      let page: FetchedPage | undefined;
      for (const address of addresses) {
        try {
          page = await dependencies.request(url, address, controller.signal);
          break;
        } catch (error) {
          if (error instanceof FetchFailure || controller.signal.aborted) throw error;
        }
      }
      if (!page) throw new FetchFailure('Could not connect to the recipe site.');
      if (page.status >= 300 && page.status < 400) {
        if (!page.location) throw new FetchFailure('Recipe redirect has no destination.');
        url = new URL(page.location, url);
        continue;
      }
      return page.text;
    }
    throw new FetchFailure('Recipe link has too many redirects.');
  } catch (error) {
    if (error instanceof FetchFailure) throw error;
    throw new FetchFailure(
      controller.signal.aborted ? 'Recipe link timed out.' : 'Could not read the recipe link.',
    );
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}
