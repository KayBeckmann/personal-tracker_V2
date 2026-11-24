// Kryptografische Grundbausteine über WebCrypto (Obsidian Desktop und
// Mobil, Node für Tests). Dieselben Verfahren wie in der App:
// AES-256-GCM, HKDF-SHA256, HMAC-SHA256, SHA-256.

const subtle = (): SubtleCrypto => globalThis.crypto.subtle;
const kodierer = new TextEncoder();

export const utf8 = (s: string): Uint8Array<ArrayBuffer> => kodierer.encode(s) as Uint8Array<ArrayBuffer>;
export const vonUtf8 = (b: Uint8Array): string => new TextDecoder().decode(b);

export function zufall(n: number): Uint8Array<ArrayBuffer> {
  const b = new Uint8Array(n);
  for (let i = 0; i < n; i += 65536) globalThis.crypto.getRandomValues(b.subarray(i, Math.min(n, i + 65536)));
  return b;
}

export function hex(b: Uint8Array): string {
  let s = '';
  for (const x of b) s += x.toString(16).padStart(2, '0');
  return s;
}

export function base64(b: Uint8Array): string {
  let s = '';
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000));
  return btoa(s);
}

export function vonBase64(s: string): Uint8Array<ArrayBuffer> {
  const roh = atob(s.replace(/-/g, '+').replace(/_/g, '/'));
  const b = new Uint8Array(roh.length);
  for (let i = 0; i < roh.length; i++) b[i] = roh.charCodeAt(i);
  return b;
}

export function base64Url(b: Uint8Array): string {
  return base64(b).replace(/\+/g, '-').replace(/\//g, '_');
}

/** HKDF-SHA256 ohne Salt (wie pointycastle mit `null`: Salt = 32 Nullbytes). */
export async function hkdf(material: Uint8Array<ArrayBuffer>, info: string, laenge = 32): Promise<Uint8Array<ArrayBuffer>> {
  const k = await subtle().importKey('raw', material, 'HKDF', false, ['deriveBits']);
  const bits = await subtle().deriveBits({ name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(32), info: utf8(info) }, k, laenge * 8);
  return new Uint8Array(bits);
}

export async function hmac(schluessel: Uint8Array<ArrayBuffer>, daten: Uint8Array<ArrayBuffer>): Promise<Uint8Array<ArrayBuffer>> {
  const k = await subtle().importKey('raw', schluessel, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await subtle().sign('HMAC', k, daten));
}

export async function sha256(daten: Uint8Array<ArrayBuffer>): Promise<string> {
  return hex(new Uint8Array(await subtle().digest('SHA-256', daten)));
}

const schluesselCache = new WeakMap<Uint8Array, Promise<CryptoKey>>();
function aesSchluessel(roh: Uint8Array<ArrayBuffer>): Promise<CryptoKey> {
  let k = schluesselCache.get(roh);
  if (!k) {
    k = subtle().importKey('raw', roh, 'AES-GCM', false, ['encrypt', 'decrypt']);
    schluesselCache.set(roh, k);
  }
  return k;
}

/** AES-256-GCM; Ergebnis ist `{nonce, daten}` mit angehängtem Tag. */
export async function verschluesseln(
  schluessel: Uint8Array<ArrayBuffer>,
  klar: Uint8Array<ArrayBuffer>,
  aad: string,
): Promise<{ nonce: Uint8Array<ArrayBuffer>; daten: Uint8Array<ArrayBuffer> }> {
  const nonce = zufall(12);
  const c = await subtle().encrypt({ name: 'AES-GCM', iv: nonce, additionalData: utf8(aad), tagLength: 128 }, await aesSchluessel(schluessel), klar);
  return { nonce, daten: new Uint8Array(c) };
}

/** `null`, wenn Schlüssel, Nonce, AAD oder Daten nicht passen. */
export async function entschluesseln(
  schluessel: Uint8Array<ArrayBuffer>,
  nonce: Uint8Array<ArrayBuffer>,
  daten: Uint8Array<ArrayBuffer>,
  aad: string,
): Promise<Uint8Array<ArrayBuffer> | null> {
  try {
    const k = await aesSchluessel(schluessel);
    return new Uint8Array(await subtle().decrypt({ name: 'AES-GCM', iv: nonce, additionalData: utf8(aad), tagLength: 128 }, k, daten));
  } catch {
    return null;
  }
}
