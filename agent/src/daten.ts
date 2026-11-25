// Sicht der Brücke auf die Tracker-Daten: holt alle Objekte des Kontos
// (und lesbarer geteilter Räume), entschlüsselt sie im Arbeitsspeicher und
// schreibt Änderungen verschlüsselt zurück. Klartext landet nie auf der
// Platte.

import { SyncApi, SyncFehler, type Transport } from '../../obsidian/src/api.ts';
import { sha256, vonBase64 } from '../../obsidian/src/krypto.ts';
import { Kontoschluessel, neueId, SCHEMA, type Umschlag, type VaultDatei } from '../../obsidian/src/protokoll.ts';
import { Raum, type RaumJson } from '../../obsidian/src/raum.ts';
import type { Zugang } from './zugang.ts';

export type Daten = Record<string, any>;

export interface Eintrag {
  bereich: string;
  id: string;
  daten: Daten;
  /** Raum, aus dem der Eintrag stammt; `undefined` = eigenes Konto. */
  raum?: string;
}

type Bytes = Uint8Array<ArrayBuffer>;

export class Datenstand {
  readonly z: Zugang;
  readonly api: SyncApi;
  readonly ks: Kontoschluessel;
  private seq = 0;
  private readonly raumSeq = new Map<string, number>();
  /** Aktuelle Einträge: `bereich|id`. */
  readonly eintraege = new Map<string, Eintrag>();
  /** Serverrevision je Eintrag im Konto (auch für Gelöschte). */
  private readonly basis = new Map<string, number>();
  readonly raeume = new Map<string, Raum>();

  constructor(z: Zugang, transport: Transport) {
    this.z = z;
    this.api = new SyncApi(z.server, transport, z.token);
    this.ks = Kontoschluessel.ausBase64(z.schluessel);
  }

  private static k(bereich: string, id: string): string {
    return `${bereich}|${id}`;
  }

  /** Holt alles Neue (Konto, dann geteilte Räume). */
  async aktualisieren(): Promise<void> {
    for (;;) {
      const r = await this.api.abrufen(this.seq, 500);
      for (const o of r.objekte) {
        const u = await this.ks.entschluesseln(o.id, o.daten);
        if (!u) continue;
        this.uebernehmen(u, o.seq);
      }
      this.seq = r.bis;
      if (!r.mehr) break;
    }
    for (const raum of this.raeume.values()) {
      let seit = this.raumSeq.get(raum.id) ?? 0;
      try {
        for (;;) {
          const r = await this.api.abrufen(seit, 500, raum.id);
          for (const o of r.objekte) {
            const u = await raum.entschluesseln(o.id, o.daten);
            if (!u || u.bereich === 'raum') continue;
            const key = Datenstand.k(u.bereich, u.id);
            if (u.daten) {
              const d: Daten = { ...u.daten, raum: raum.id };
              if (u.bereich === 'vault' && raum.ordner) d.pfad = `${raum.ordner}/${d.pfad}`;
              this.eintraege.set(key, { bereich: u.bereich, id: u.id, daten: d, raum: raum.id });
            } else if (this.eintraege.get(key)?.raum === raum.id) {
              this.eintraege.delete(key);
            }
          }
          seit = r.bis;
          if (!r.mehr) break;
        }
        this.raumSeq.set(raum.id, seit);
      } catch (e) {
        // Kein Zugang mehr: Inhalte des Raums vergessen.
        if (e instanceof SyncFehler && e.art === 'nichtGefunden') {
          for (const [k, v] of this.eintraege) if (v.raum === raum.id) this.eintraege.delete(k);
          this.raeume.delete(raum.id);
        } else {
          throw e;
        }
      }
    }
  }

  private uebernehmen(u: Umschlag, seq: number): void {
    const key = Datenstand.k(u.bereich, u.id);
    this.basis.set(key, seq);
    if (u.bereich === 'raeume') {
      if (u.daten) {
        const r = new Raum(u.daten as unknown as RaumJson);
        this.raeume.set(r.id, r);
      } else {
        this.raeume.delete(u.id);
      }
    }
    if (u.daten) this.eintraege.set(key, { bereich: u.bereich, id: u.id, daten: u.daten as Daten });
    else if (!this.eintraege.get(key)?.raum) this.eintraege.delete(key);
  }

  alle(bereich: string): Eintrag[] {
    return [...this.eintraege.values()].filter((e) => e.bereich === bereich);
  }

  eins(bereich: string, id: string): Eintrag | undefined {
    return this.eintraege.get(Datenstand.k(bereich, id));
  }

  /** Schreibt (oder löscht mit `null`) einen Eintrag im eigenen Konto. */
  async schreiben(bereich: string, id: string, daten: Daten | null): Promise<void> {
    const key = Datenstand.k(bereich, id);
    const vorher = this.eintraege.get(key);
    if (vorher?.raum) throw new Error('Geteilte Einträge ändert der Agent nicht; das geht nur in der App.');
    const u: Umschlag = { bereich, id, schema: SCHEMA, daten };
    const [r] = await this.api.schreiben([
      { id: await this.ks.objektId(bereich, id), basis: this.basis.get(key) ?? 0, aenderung: neueId(), daten: await this.ks.verschluesseln(u) },
    ]);
    if (!r.ok) {
      await this.aktualisieren();
      throw new Error('Der Eintrag wurde gerade woanders geändert. Bitte noch einmal versuchen.');
    }
    this.basis.set(key, r.seq);
    if (r.seq > this.seq && this.seq === r.seq - 1) this.seq = r.seq;
    if (daten) this.eintraege.set(key, { bereich, id, daten });
    else this.eintraege.delete(key);
  }

  /** Inhalt einer Vault-Datei (direkt oder aus Blöcken). */
  async vaultInhalt(e: Eintrag): Promise<Bytes> {
    const d = e.daten as unknown as VaultDatei;
    if (d.inhalt !== undefined) return vonBase64(d.inhalt);
    const raum = e.raum ? this.raeume.get(e.raum) : undefined;
    const teile: Bytes[] = [];
    for (const b of d.bloecke ?? []) {
      const geheim = await this.api.blockLesen(b.id, raum?.id);
      const klar = raum ? await raum.blockEntschluesseln(b.id, geheim, b.groesse) : await this.ks.blockEntschluesseln(b.id, geheim, b.groesse);
      if (!klar) throw new Error('Ein Teil der Datei ließ sich nicht entschlüsseln.');
      teile.push(klar);
    }
    const alles = new Uint8Array(teile.reduce((n, t) => n + t.length, 0));
    let o = 0;
    for (const t of teile) {
      alles.set(t, o);
      o += t.length;
    }
    if ((await sha256(alles)) !== d.sha256) throw new Error('Die Datei ist unvollständig.');
    return alles;
  }

  /** Neue oder geänderte Vault-Datei im eigenen Konto (Blöcke bei Bedarf). */
  async vaultSchreiben(id: string, pfad: string, inhalt: Bytes): Promise<void> {
    const bloecke = new Map<string, Bytes>();
    const d = await this.ks.vaultDatei(id, pfad, inhalt, new Date(), bloecke);
    if (bloecke.size > 0) {
      for (const bid of await this.api.bloeckeFehlend([...bloecke.keys()])) {
        await this.api.blockSchreiben(bid, await this.ks.blockVerschluesseln(bid, bloecke.get(bid)!));
      }
    }
    await this.schreiben('vault', id, d as unknown as Daten);
  }
}
