// Zugangsdaten der Brücke (Token, Kontoschlüssel, Rechte) liegen nur
// verschlüsselt auf diesem Rechner: AES-256-GCM mit einem Schlüssel aus der
// Passphrase (scrypt). Ohne Passphrase ist die Datei nutzlos.

import { createCipheriv, createDecipheriv, randomBytes, scryptSync } from 'node:crypto';
import { execSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, existsSync, chmodSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

export type Recht = 'lesen' | 'schreiben';
export const MODULE = ['termine', 'aufgaben', 'notizen', 'haushaltsbuch', 'einkauf', 'vault'] as const;
export type Modul = (typeof MODULE)[number];

export interface Zugang {
  server: string;
  konto: string;
  geraet: string;
  token: string;
  /** Kontoschlüssel (base64). */
  schluessel: string;
  agent: { id: string; name: string; rechte: Partial<Record<Modul, Recht>> };
}

export function zugangsDatei(): string {
  return process.env.PT_AGENT_DATEI ?? join(process.env.XDG_CONFIG_HOME ?? join(homedir(), '.config'), 'personal-tracker-agent', 'zugang.json');
}

/** Passphrase aus `PT_AGENT_PASSPHRASE` oder einem Befehl (`PT_AGENT_PASSPHRASE_BEFEHL`, z. B. `pass show tracker/agent`). */
export function passphrase(): string {
  const p = process.env.PT_AGENT_PASSPHRASE;
  if (p) return p;
  const befehl = process.env.PT_AGENT_PASSPHRASE_BEFEHL;
  if (befehl) return execSync(befehl, { encoding: 'utf8' }).split('\n')[0];
  throw new Error('Keine Passphrase: PT_AGENT_PASSPHRASE oder PT_AGENT_PASSPHRASE_BEFEHL setzen.');
}

const SCRYPT = { N: 1 << 15, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };

export function speichern(z: Zugang, pw: string, datei = zugangsDatei()): void {
  if (pw.length < 8) throw new Error('Die Passphrase braucht mindestens 8 Zeichen.');
  const salz = randomBytes(16);
  const k = scryptSync(pw, salz, 32, SCRYPT);
  const nonce = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', k, nonce);
  c.setAAD(Buffer.from('ptv2-agent-zugang-v1'));
  const daten = Buffer.concat([c.update(JSON.stringify(z), 'utf8'), c.final(), c.getAuthTag()]);
  mkdirSync(dirname(datei), { recursive: true, mode: 0o700 });
  writeFileSync(datei, JSON.stringify({ v: 1, salz: salz.toString('base64'), nonce: nonce.toString('base64'), daten: daten.toString('base64') }), { mode: 0o600 });
  chmodSync(datei, 0o600);
}

export function laden(pw: string, datei = zugangsDatei()): Zugang {
  if (!existsSync(datei)) throw new Error(`Noch nicht gekoppelt (${datei} fehlt). Zuerst: pt-agent koppeln …`);
  const j = JSON.parse(readFileSync(datei, 'utf8'));
  const k = scryptSync(pw, Buffer.from(j.salz, 'base64'), 32, SCRYPT);
  const roh = Buffer.from(j.daten, 'base64');
  const d = createDecipheriv('aes-256-gcm', k, Buffer.from(j.nonce, 'base64'));
  d.setAAD(Buffer.from('ptv2-agent-zugang-v1'));
  d.setAuthTag(roh.subarray(roh.length - 16));
  try {
    return JSON.parse(Buffer.concat([d.update(roh.subarray(0, roh.length - 16)), d.final()]).toString('utf8'));
  } catch {
    throw new Error('Falsche Passphrase oder beschädigte Zugangsdatei.');
  }
}
