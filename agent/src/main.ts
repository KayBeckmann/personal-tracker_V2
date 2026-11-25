#!/usr/bin/env node
// pt-agent – lokale MCP-Brücke für den eigenen KI-Agenten.
//
//   pt-agent koppeln --server https://sync.example.org --code XXXX-…   (Code aus der App)
//   pt-agent mcp        MCP-Server über stdio (für Claude Code, Claude Desktop u. a.)
//   pt-agent status     Verbindung und Rechte anzeigen
//   pt-agent abmelden   Zugang beim Server abmelden und Zugangsdatei löschen
//
// Passphrase: PT_AGENT_PASSPHRASE oder PT_AGENT_PASSPHRASE_BEFEHL (z. B.
// `pass show tracker/agent`); beim Koppeln sonst interaktiv.

import { rmSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';

import { fetchTransport, SyncApi, SyncFehler, serverAdresse } from '../../obsidian/src/api.ts';
import { Kopplungscode } from '../../obsidian/src/protokoll.ts';
import { Datenstand } from './daten.ts';
import { werkzeugeRegistrieren } from './werkzeuge.ts';
import { laden, MODULE, passphrase, speichern, zugangsDatei, type Modul, type Recht, type Zugang } from './zugang.ts';

export const VERSION = '0.1.0';

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

async function frage(text: string, verdeckt = false): Promise<string> {
  const rl = createInterface({ input: process.stdin, output: process.stderr, terminal: true });
  if (verdeckt) (rl as unknown as { _writeToOutput: (s: string) => void })._writeToOutput = (s: string) => process.stderr.write(s.includes(text) ? s : '');
  return new Promise((ok) =>
    rl.question(text, (a) => {
      rl.close();
      if (verdeckt) process.stderr.write('\n');
      ok(a);
    }),
  );
}

async function neuePassphrase(): Promise<string> {
  if (process.env.PT_AGENT_PASSPHRASE || process.env.PT_AGENT_PASSPHRASE_BEFEHL) return passphrase();
  const a = await frage('Passphrase für die Zugangsdatei: ', true);
  const b = await frage('Noch einmal: ', true);
  if (a !== b) throw new Error('Die Passphrasen stimmen nicht überein.');
  return a;
}

/** Löst einen Agenten-Kopplungscode aus der App ein. */
export async function koppeln(server: string, codeText: string, transport = fetchTransport): Promise<Zugang> {
  const code = Kopplungscode.lesen(codeText);
  if (!code) throw new Error('Der Kopplungscode hat 20 Zeichen.');
  const api = new SyncApi(serverAdresse(server), transport);
  await api.info();
  const e = await api.kopplungEinloesen(await code.slot(), '');
  const p = await code.paketOeffnen(e.paket);
  if (!p) throw new Error('Das Kopplungspaket ließ sich nicht öffnen.');
  const a = p.agent as { id?: unknown; name?: unknown; rechte?: unknown } | undefined;
  const mitToken = api.mitToken(e.token);
  if (!a || typeof a.id !== 'string' || typeof a.name !== 'string' || typeof a.rechte !== 'object' || !a.rechte) {
    // Ein normaler Geräte-Code: sofort wieder abmelden, keine vollen Rechte für die Brücke.
    await mitToken.geraetEntfernen(e.geraet).catch(() => {});
    throw new Error('Das ist kein Agenten-Code. In der App unter „KI-Agent verbinden“ einen erzeugen.');
  }
  const rechte: Partial<Record<Modul, Recht>> = {};
  for (const m of MODULE) {
    const r = (a.rechte as Record<string, unknown>)[m];
    if (r === 'lesen' || r === 'schreiben') rechte[m] = r;
  }
  const konto = await mitToken.konto();
  if (!(await p.schluessel.passtZuPaket(konto.schluesselPaket))) throw new Error('Der Schlüssel passt nicht zum Konto.');
  await mitToken.geraetUmbenennen(e.geraet, await p.schluessel.geraetName(`Agent: ${a.name}`));
  const { base64 } = await import('../../obsidian/src/krypto.ts');
  return {
    server: serverAdresse(server),
    konto: e.konto,
    geraet: e.geraet,
    token: e.token,
    schluessel: base64(p.schluessel.bytes),
    agent: { id: a.id, name: a.name, rechte },
  };
}

export async function mcpServer(z: Zugang, transport = fetchTransport): Promise<{ server: McpServer; werkzeuge: string[]; ds: Datenstand }> {
  const ds = new Datenstand(z, transport);
  await ds.aktualisieren();
  const server = new McpServer(
    { name: 'personal-tracker', version: VERSION },
    {
      instructions:
        `Zugriff auf den Personal Tracker von „${z.agent.name}“ (nur freigegebene Module: ${Object.entries(z.agent.rechte).map(([m, r]) => `${m}: ${r}`).join(', ') || 'keine'}). ` +
        'Löschen und Veröffentlichen sind nur Vorschläge, die die Person in der App bestätigt. Geteilte Einträge sind nur lesbar.',
    },
  );
  const werkzeuge = werkzeugeRegistrieren(server, ds, z);
  return { server, werkzeuge, ds };
}

async function main(): Promise<void> {
  const befehl = process.argv[2];
  switch (befehl) {
    case 'koppeln': {
      const server = arg('server'), code = arg('code');
      if (!server || !code) throw new Error('Aufruf: pt-agent koppeln --server <adresse> --code <kopplungscode>');
      const z = await koppeln(server, code);
      speichern(z, await neuePassphrase());
      process.stderr.write(`Gekoppelt als „${z.agent.name}“. Rechte: ${JSON.stringify(z.agent.rechte)}\nZugangsdatei: ${zugangsDatei()}\n`);
      return;
    }
    case 'mcp': {
      const z = laden(passphrase());
      const { server, werkzeuge } = await mcpServer(z);
      process.stderr.write(`pt-agent ${VERSION}: ${werkzeuge.length} Werkzeuge für „${z.agent.name}“\n`);
      await server.connect(new StdioServerTransport());
      return;
    }
    case 'status': {
      const z = laden(passphrase());
      const ds = new Datenstand(z, fetchTransport);
      await ds.aktualisieren();
      process.stdout.write(`Agent „${z.agent.name}“ an ${z.server}\nRechte: ${JSON.stringify(z.agent.rechte)}\nVerbindung: in Ordnung\n`);
      return;
    }
    case 'abmelden': {
      const z = laden(passphrase());
      try {
        await new SyncApi(z.server, fetchTransport, z.token).geraetEntfernen(z.geraet);
      } catch (e) {
        if (!(e instanceof SyncFehler && e.art === 'anmeldung')) throw e;
      }
      rmSync(zugangsDatei());
      process.stdout.write('Abgemeldet; Zugangsdatei gelöscht.\n');
      return;
    }
    default:
      process.stderr.write('Befehle: koppeln --server <adresse> --code <code> | mcp | status | abmelden\n');
      process.exitCode = 64;
  }
}

if (process.argv[1] && /pt-agent|main\.ts$/.test(process.argv[1])) {
  main().catch((e) => {
    process.stderr.write(`${e instanceof Error ? e.message : e}\n`);
    process.exitCode = 1;
  });
}
