// MCP-Werkzeuge der Brücke. Welche es gibt, bestimmen die Rechte des
// Agenten-Zugangs (je Modul lesen oder lesen+schreiben). Jeder Aufruf
// wird ohne Inhalte protokolliert (für die App sichtbar). Löschen und
// Veröffentlichen sind nur Vorschläge, die in der App bestätigt werden.
// Teilen mit anderen Personen gibt es für Agenten nicht.

import { z } from 'zod';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';

import { utf8, vonUtf8 } from '../../obsidian/src/krypto.ts';
import { neueId, vaultPfad } from '../../obsidian/src/protokoll.ts';
import { pruefen } from '../../obsidian/src/secrets.ts';
import type { Daten, Datenstand, Eintrag } from './daten.ts';
import type { Modul, Recht, Zugang } from './zugang.ts';

const tag = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Datum als JJJJ-MM-TT');
const zeit = z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/, 'Zeit als JJJJ-MM-TTTHH:MM (Ortszeit)');

type Antwort = { content: { type: 'text'; text: string }[]; isError?: boolean };
const ok = (x: unknown): Antwort => ({ content: [{ type: 'text', text: typeof x === 'string' ? x : JSON.stringify(x, null, 2) }] });
const fehler = (m: string): Antwort => ({ content: [{ type: 'text', text: m }], isError: true });

const enthaelt = (t: unknown, s?: string) => !s || String(t ?? '').toLowerCase().includes(s.toLowerCase());
const jetzt = () => new Date().toISOString();

/** Registriert alle erlaubten Werkzeuge; liefert ihre Namen. */
export function werkzeugeRegistrieren(server: McpServer, ds: Datenstand, zugang: Zugang): string[] {
  const rechte = zugang.agent.rechte;
  const namen: string[] = [];

  async function protokoll(werkzeug: string, modul: Modul, art: 'lesen' | 'schreiben' | 'vorschlag', anzahl: number): Promise<void> {
    const id = neueId();
    try {
      await ds.schreiben('agent_protokoll', id, { id, agent: zugang.agent.id, geraet: zugang.geraet, zeit: jetzt(), werkzeug, modul, art, anzahl });
    } catch (e) {
      process.stderr.write(`Protokoll nicht geschrieben: ${e}\n`);
    }
  }

  async function vorschlagen(modul: Modul, art: 'loeschen' | 'veroeffentlichen', bereich: string, ziel: Eintrag, beschreibung: string): Promise<Antwort> {
    const id = neueId();
    await ds.schreiben('agent_vorschlaege', id, {
      id,
      agent: zugang.agent.id,
      agentName: zugang.agent.name,
      zeit: jetzt(),
      art,
      bereich,
      zielId: ziel.id,
      beschreibung,
      status: 'offen',
    });
    await protokoll(`${bereich}_${art}`, modul, 'vorschlag', 1);
    return ok(`Vorschlag angelegt: ${beschreibung}. Er wird erst ausgeführt, wenn die Person ihn in der App bestätigt.`);
  }

  function werkzeug<S extends z.ZodRawShape>(
    name: string,
    modul: Modul,
    recht: Recht,
    beschreibung: string,
    schema: S,
    f: (a: z.infer<z.ZodObject<S>>) => Promise<Antwort>,
  ): void {
    const hat = rechte[modul];
    if (!hat || (recht === 'schreiben' && hat !== 'schreiben')) return;
    namen.push(name);
    server.registerTool(name, { description: beschreibung, inputSchema: schema }, (async (a: z.infer<z.ZodObject<S>>) => {
      try {
        await ds.aktualisieren();
        return await f(a);
      } catch (e) {
        return fehler(e instanceof Error ? e.message : String(e));
      }
    }) as never);
  }

  // ---------------------------------------------------------------- Termine

  werkzeug('termine_suchen', 'termine', 'lesen', 'Termine suchen (Titel, Ort, Notiz) im Zeitraum; Zeiten sind Ortszeit. Wiederkehrende Termine erscheinen mit ihrer Regel.', {
    text: z.string().optional(),
    von: tag.optional(),
    bis: tag.optional(),
  }, async ({ text, von, bis }) => {
    const t = ds
      .alle('termine')
      .filter((e) => enthaelt(e.daten.titel, text) || enthaelt(e.daten.ort, text) || enthaelt(e.daten.notiz, text))
      .filter((e) => e.daten.wiederholung || ((!von || String(e.daten.ende ?? e.daten.beginn) >= von) && (!bis || String(e.daten.beginn) <= `${bis}T23:59`)))
      .map((e) => ({ ...termin(e.daten), geteilt: !!e.raum }));
    await protokoll('termine_suchen', 'termine', 'lesen', t.length);
    return ok(t);
  });

  werkzeug('termin_anlegen', 'termine', 'schreiben', 'Neuen privaten Termin anlegen.', {
    titel: z.string().min(1).max(200),
    beginn: zeit,
    ende: zeit.optional(),
    ganztaegig: z.boolean().optional(),
    ort: z.string().max(200).optional(),
    notiz: z.string().max(5000).optional(),
  }, async (a) => {
    const id = neueId();
    const d: Daten = { id, titel: a.titel, beginn: a.beginn, ganztaegig: a.ganztaegig ?? false, geaendert: jetzt() };
    if (a.ende) d.ende = a.ende;
    if (a.ort) d.ort = a.ort;
    if (a.notiz) d.notiz = a.notiz;
    await ds.schreiben('termine', id, d);
    await protokoll('termin_anlegen', 'termine', 'schreiben', 1);
    return ok({ angelegt: termin(d) });
  });

  werkzeug('termin_aendern', 'termine', 'schreiben', 'Titel, Zeit, Ort oder Notiz eines privaten Termins ändern.', {
    id: z.string(),
    titel: z.string().min(1).max(200).optional(),
    beginn: zeit.optional(),
    ende: zeit.optional(),
    ort: z.string().max(200).optional(),
    notiz: z.string().max(5000).optional(),
  }, async ({ id, ...neu }) => {
    const e = ds.eins('termine', id);
    if (!e) return fehler('Termin nicht gefunden.');
    const d = { ...e.daten, ...Object.fromEntries(Object.entries(neu).filter(([, v]) => v !== undefined)), geaendert: jetzt() };
    await ds.schreiben('termine', id, d);
    await protokoll('termin_aendern', 'termine', 'schreiben', 1);
    return ok({ geaendert: termin(d) });
  });

  werkzeug('termin_loeschen', 'termine', 'schreiben', 'Löschen eines Termins vorschlagen (die Person bestätigt in der App).', { id: z.string() }, async ({ id }) => {
    const e = ds.eins('termine', id);
    if (!e) return fehler('Termin nicht gefunden.');
    if (e.raum) return fehler('Geteilte Termine löscht nur die Person selbst in der App.');
    return vorschlagen('termine', 'loeschen', 'termine', e, `Termin „${e.daten.titel}“ löschen`);
  });

  // ---------------------------------------------------------------- Aufgaben

  werkzeug('aufgaben_suchen', 'aufgaben', 'lesen', 'Aufgaben suchen; standardmäßig nur offene.', {
    text: z.string().optional(),
    auchErledigte: z.boolean().optional(),
  }, async ({ text, auchErledigte }) => {
    const a = ds
      .alle('aufgaben')
      .filter((e) => (auchErledigte || !e.daten.erledigt) && (enthaelt(e.daten.titel, text) || enthaelt(e.daten.notiz, text)))
      .map((e) => ({ id: e.id, titel: e.daten.titel, faellig: e.daten.faellig, prioritaet: e.daten.prioritaet, erledigt: e.daten.erledigt ?? null, notiz: e.daten.notiz, wiederholung: e.daten.wiederholung ?? null, geteilt: !!e.raum }));
    await protokoll('aufgaben_suchen', 'aufgaben', 'lesen', a.length);
    return ok(a);
  });

  werkzeug('aufgabe_anlegen', 'aufgaben', 'schreiben', 'Neue private Aufgabe anlegen.', {
    titel: z.string().min(1).max(200),
    faellig: tag.optional(),
    prioritaet: z.enum(['niedrig', 'normal', 'hoch']).optional(),
    notiz: z.string().max(5000).optional(),
  }, async (a) => {
    const id = neueId();
    const d: Daten = { id, titel: a.titel, prioritaet: a.prioritaet ?? 'normal', geaendert: jetzt() };
    if (a.faellig) d.faellig = a.faellig;
    if (a.notiz) d.notiz = a.notiz;
    await ds.schreiben('aufgaben', id, d);
    await protokoll('aufgabe_anlegen', 'aufgaben', 'schreiben', 1);
    return ok({ angelegt: d });
  });

  werkzeug('aufgabe_erledigen', 'aufgaben', 'schreiben', 'Eine (nicht wiederkehrende) private Aufgabe als erledigt markieren.', { id: z.string() }, async ({ id }) => {
    const e = ds.eins('aufgaben', id);
    if (!e) return fehler('Aufgabe nicht gefunden.');
    if (e.daten.wiederholung) return fehler('Wiederkehrende Aufgaben bitte in der App abhaken (dort wird die nächste Runde berechnet).');
    await ds.schreiben('aufgaben', id, { ...e.daten, erledigt: jetzt(), geaendert: jetzt() });
    await protokoll('aufgabe_erledigen', 'aufgaben', 'schreiben', 1);
    return ok('Erledigt.');
  });

  werkzeug('aufgabe_loeschen', 'aufgaben', 'schreiben', 'Löschen einer Aufgabe vorschlagen (Bestätigung in der App).', { id: z.string() }, async ({ id }) => {
    const e = ds.eins('aufgaben', id);
    if (!e) return fehler('Aufgabe nicht gefunden.');
    if (e.raum) return fehler('Geteilte Aufgaben löscht nur die Person selbst in der App.');
    return vorschlagen('aufgaben', 'loeschen', 'aufgaben', e, `Aufgabe „${e.daten.titel}“ löschen`);
  });

  // ---------------------------------------------------------------- Notizen

  werkzeug('notizen_suchen', 'notizen', 'lesen', 'Notizen nach Text durchsuchen (liefert Titel und Anfang).', { text: z.string().optional() }, async ({ text }) => {
    const n = ds
      .alle('notizen')
      .filter((e) => enthaelt(e.daten.titel, text) || enthaelt(e.daten.text, text))
      .map((e) => ({ id: e.id, titel: e.daten.titel, anfang: String(e.daten.text ?? '').slice(0, 200), geaendert: e.daten.geaendert }));
    await protokoll('notizen_suchen', 'notizen', 'lesen', n.length);
    return ok(n);
  });

  werkzeug('notiz_lesen', 'notizen', 'lesen', 'Eine Notiz vollständig lesen (Markdown).', { id: z.string() }, async ({ id }) => {
    const e = ds.eins('notizen', id);
    if (!e) return fehler('Notiz nicht gefunden.');
    await protokoll('notiz_lesen', 'notizen', 'lesen', 1);
    return ok({ id, titel: e.daten.titel, text: e.daten.text });
  });

  werkzeug('notiz_anlegen', 'notizen', 'schreiben', 'Neue Markdown-Notiz anlegen.', { titel: z.string().max(200), text: z.string().max(200000) }, async ({ titel, text }) => {
    const id = neueId();
    const d = { id, titel, text, erstellt: jetzt(), geaendert: jetzt() };
    await ds.schreiben('notizen', id, d);
    await protokoll('notiz_anlegen', 'notizen', 'schreiben', 1);
    return ok({ angelegt: { id, titel } });
  });

  werkzeug('notiz_aendern', 'notizen', 'schreiben', 'Titel oder Text einer Notiz ersetzen.', {
    id: z.string(),
    titel: z.string().max(200).optional(),
    text: z.string().max(200000).optional(),
  }, async ({ id, titel, text }) => {
    const e = ds.eins('notizen', id);
    if (!e) return fehler('Notiz nicht gefunden.');
    await ds.schreiben('notizen', id, { ...e.daten, ...(titel !== undefined ? { titel } : {}), ...(text !== undefined ? { text } : {}), geaendert: jetzt() });
    await protokoll('notiz_aendern', 'notizen', 'schreiben', 1);
    return ok('Geändert.');
  });

  werkzeug('notiz_loeschen', 'notizen', 'schreiben', 'Löschen einer Notiz vorschlagen (Bestätigung in der App).', { id: z.string() }, async ({ id }) => {
    const e = ds.eins('notizen', id);
    if (!e) return fehler('Notiz nicht gefunden.');
    return vorschlagen('notizen', 'loeschen', 'notizen', e, `Notiz „${e.daten.titel || 'ohne Titel'}“ löschen`);
  });

  // ---------------------------------------------------------------- Haushaltsbuch

  werkzeug('konten_auflisten', 'haushaltsbuch', 'lesen', 'Konten mit aktuellem Stand (nur gebuchte Beträge, in Cent).', {}, async () => {
    const buchungen = ds.alle('buchungen');
    const k = ds.alle('konten').map((e) => ({
      id: e.id,
      name: e.daten.name,
      art: e.daten.art,
      archiviert: !!e.daten.archiviert,
      standCent: (e.daten.anfangssaldoCent ?? 0) + buchungen.filter((b) => b.daten.kontoId === e.id && b.daten.status === 'gebucht').reduce((n, b) => n + (b.daten.betragCent as number), 0),
    }));
    await protokoll('konten_auflisten', 'haushaltsbuch', 'lesen', k.length);
    return ok(k);
  });

  werkzeug('buchungen_suchen', 'haushaltsbuch', 'lesen', 'Buchungen im Zeitraum, optional nach Text und Konto (Beträge in Cent, Ausgaben negativ).', {
    von: tag.optional(),
    bis: tag.optional(),
    text: z.string().optional(),
    kontoId: z.string().optional(),
  }, async ({ von, bis, text, kontoId }) => {
    const b = ds
      .alle('buchungen')
      .filter((e) => (!von || e.daten.datum >= von) && (!bis || e.daten.datum <= bis) && (!kontoId || e.daten.kontoId === kontoId))
      .filter((e) => enthaelt(e.daten.empfaenger, text) || enthaelt(e.daten.bemerkung, text))
      .map((e) => ({ id: e.id, datum: e.daten.datum, kontoId: e.daten.kontoId, empfaenger: e.daten.empfaenger, betragCent: e.daten.betragCent, status: e.daten.status, bemerkung: e.daten.bemerkung, umbuchung: !!e.daten.umbuchungId }))
      .sort((x, y) => String(y.datum).localeCompare(String(x.datum)));
    await protokoll('buchungen_suchen', 'haushaltsbuch', 'lesen', b.length);
    return ok(b);
  });

  werkzeug('buchung_anlegen', 'haushaltsbuch', 'schreiben', 'Eine Einnahme (positiv) oder Ausgabe (negativ, in Cent) auf einem Konto buchen oder planen.', {
    kontoId: z.string(),
    betragCent: z.number().int().refine((x) => x !== 0, 'Betrag darf nicht 0 sein'),
    datum: tag,
    empfaenger: z.string().min(1).max(200),
    status: z.enum(['gebucht', 'geplant']).optional(),
    bemerkung: z.string().max(1000).optional(),
  }, async (a) => {
    if (!ds.eins('konten', a.kontoId)) return fehler('Konto nicht gefunden.');
    const id = neueId();
    const d: Daten = { id, kontoId: a.kontoId, datum: a.datum, empfaenger: a.empfaenger, betragCent: a.betragCent, status: a.status ?? 'gebucht', geaendert: jetzt() };
    if (a.bemerkung) d.bemerkung = a.bemerkung;
    await ds.schreiben('buchungen', id, d);
    await protokoll('buchung_anlegen', 'haushaltsbuch', 'schreiben', 1);
    return ok({ angelegt: d });
  });

  werkzeug('buchung_loeschen', 'haushaltsbuch', 'schreiben', 'Löschen einer Buchung vorschlagen (Bestätigung in der App).', { id: z.string() }, async ({ id }) => {
    const e = ds.eins('buchungen', id);
    if (!e) return fehler('Buchung nicht gefunden.');
    return vorschlagen('haushaltsbuch', 'loeschen', 'buchungen', e, `Buchung „${e.daten.empfaenger}“ (${(e.daten.betragCent / 100).toFixed(2).replace('.', ',')} €, ${e.daten.datum}) löschen`);
  });

  // ---------------------------------------------------------------- Einkauf

  werkzeug('einkaufslisten', 'einkauf', 'lesen', 'Einkaufslisten mit offenen Posten.', {}, async () => {
    const posten = ds.alle('posten').filter((p) => !p.daten.einkaufId);
    const l = ds.alle('einkaufslisten').map((e) => ({
      id: e.id,
      name: e.daten.name,
      geteilt: !!e.raum,
      posten: posten.filter((p) => p.daten.listeId === e.id).map((p) => ({ id: p.id, name: p.daten.name, menge: p.daten.menge, einheit: p.daten.einheit, abgehakt: !!p.daten.abgehakt })),
    }));
    await protokoll('einkaufslisten', 'einkauf', 'lesen', l.length);
    return ok(l);
  });

  werkzeug('posten_hinzufuegen', 'einkauf', 'schreiben', 'Einen Posten auf eine private Einkaufsliste setzen.', {
    listeId: z.string(),
    name: z.string().min(1).max(100),
    menge: z.number().positive().optional(),
    einheit: z.enum(['stueck', 'packung', 'g', 'kg', 'ml', 'l']).optional(),
  }, async (a) => {
    const l = ds.eins('einkaufslisten', a.listeId);
    if (!l) return fehler('Liste nicht gefunden.');
    if (l.raum) return fehler('Geteilte Listen ändert nur die Person selbst in der App.');
    const id = neueId();
    await ds.schreiben('posten', id, { id, listeId: a.listeId, name: a.name, menge: a.menge ?? 1, einheit: a.einheit ?? 'stueck', geaendert: jetzt() });
    await protokoll('posten_hinzufuegen', 'einkauf', 'schreiben', 1);
    return ok('Hinzugefügt.');
  });

  werkzeug('preis_veroeffentlichen', 'einkauf', 'schreiben', 'Vorschlagen, einen eigenen Preis im öffentlichen Katalog zu veröffentlichen (Bestätigung in der App).', { preisId: z.string() }, async ({ preisId }) => {
    const e = ds.eins('preise', preisId);
    if (!e) return fehler('Preis nicht gefunden.');
    return vorschlagen('einkauf', 'veroeffentlichen', 'preise', e, `Preis für „${e.daten.artikel}“ öffentlich im Katalog veröffentlichen`);
  });

  // ---------------------------------------------------------------- Vault

  werkzeug('vault_suchen', 'vault', 'lesen', 'Dateien im Vault nach Pfad oder Markdown-Text suchen.', { text: z.string().optional() }, async ({ text }) => {
    const treffer = ds
      .alle('vault')
      .filter((e) => enthaelt(e.daten.pfad, text) || (String(e.daten.pfad).endsWith('.md') && e.daten.inhalt && enthaelt(vonUtf8(Buffer.from(e.daten.inhalt, 'base64')), text)))
      .map((e) => ({ pfad: e.daten.pfad, groesse: e.daten.groesse, geaendert: e.daten.geaendert, geteilt: !!e.raum }))
      .sort((a, b) => String(a.pfad).localeCompare(String(b.pfad)));
    await protokoll('vault_suchen', 'vault', 'lesen', treffer.length);
    return ok(treffer.slice(0, 500));
  });

  werkzeug('vault_lesen', 'vault', 'lesen', 'Eine Text- oder Markdown-Datei aus dem Vault lesen (bis 1 MiB).', { pfad: z.string() }, async ({ pfad }) => {
    const e = ds.alle('vault').find((x) => x.daten.pfad === pfad);
    if (!e) return fehler('Datei nicht gefunden.');
    if ((e.daten.groesse as number) > 1024 * 1024) return fehler('Datei zu groß für den Agenten.');
    const b = await ds.vaultInhalt(e);
    if (b.subarray(0, 8192).includes(0)) return fehler('Binärdatei – nur Text und Markdown lassen sich lesen.');
    await protokoll('vault_lesen', 'vault', 'lesen', 1);
    return ok(vonUtf8(b));
  });

  werkzeug('vault_schreiben', 'vault', 'schreiben', 'Eine Markdown-Datei im eigenen Vault anlegen oder ersetzen. Mögliche Secrets werden nicht geschrieben.', {
    pfad: z.string().regex(/\.md$/, 'nur Markdown-Dateien (.md)'),
    inhalt: z.string().max(1024 * 1024),
  }, async ({ pfad, inhalt }) => {
    try {
      vaultPfad(pfad);
    } catch {
      return fehler('Ungültiger Pfad.');
    }
    const bytes = utf8(inhalt);
    const t = pruefen(bytes);
    if (t && t.length > 0) return fehler(`Nicht geschrieben: möglicherweise ein Secret (${t.map((x) => `${x.regel}, Zeile ${x.zeile}`).join('; ')}).`);
    const alt = ds.alle('vault').find((x) => x.daten.pfad === pfad);
    if (alt?.raum) return fehler('Dateien in geteilten Ordnern ändert nur die Person selbst.');
    await ds.vaultSchreiben(alt?.id ?? neueId(), pfad, bytes);
    await protokoll('vault_schreiben', 'vault', 'schreiben', 1);
    return ok(alt ? 'Ersetzt.' : 'Angelegt.');
  });

  werkzeug('vault_loeschen', 'vault', 'schreiben', 'Löschen einer Vault-Datei vorschlagen (Bestätigung in der App).', { pfad: z.string() }, async ({ pfad }) => {
    const e = ds.alle('vault').find((x) => x.daten.pfad === pfad);
    if (!e) return fehler('Datei nicht gefunden.');
    if (e.raum) return fehler('Dateien in geteilten Ordnern löscht nur die Person selbst.');
    return vorschlagen('vault', 'loeschen', 'vault', e, `Datei „${pfad}“ löschen`);
  });

  return namen;
}

function termin(d: Daten) {
  return {
    id: d.id,
    titel: d.titel,
    beginn: d.beginn,
    ende: d.ende ?? null,
    ganztaegig: !!d.ganztaegig,
    ort: d.ort ?? null,
    notiz: d.notiz ?? null,
    wiederholung: d.wiederholung ?? null,
  };
}
