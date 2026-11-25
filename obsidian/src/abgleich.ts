// Abgleich des Vault-Ordners mit dem Server (Regeln: protokoll/VAULT.md,
// geteilte Ordner: protokoll/RAEUME.md).
//
// Ablauf: Ordner durchsehen (neue, geänderte, verschobene, gelöschte
// Dateien) → alles Neue holen und einspielen, erst aus dem eigenen Konto,
// dann aus jedem geteilten Ordner → Ausstehendes senden, jeweils an den Ort,
// zu dem der Pfad gehört; meldet der Server einen Konflikt, wiederholen.
//
// Vor der ausdrücklichen Einrichtung (Vorschau bestätigt) wird weder
// geschrieben noch hochgeladen.

import { SyncApi, SyncFehler } from './api.ts';
import { sha256, vonBase64 } from './krypto.ts';
import { ausnahme, Kontoschluessel, konfliktPfad, neueId, SCHEMA, type Umschlag, VAULT_BEREICH, type VaultDatei, vaultPfad } from './protokoll.ts';
import { Raum, type RaumJson } from './raum.ts';
import { pruefen, type SecretTreffer } from './secrets.ts';

type Bytes = Uint8Array<ArrayBuffer>;

export interface DateiInfo {
  pfad: string;
  groesse: number;
  mtime: number;
}

/** Zugriff auf den Vault-Ordner (Obsidian-Adapter oder Test im Speicher). */
export interface Dateisystem {
  /** Alle Dateien, auch in versteckten Ordnern. */
  liste(): Promise<DateiInfo[]>;
  stat(pfad: string): Promise<DateiInfo | null>;
  lesen(pfad: string): Promise<Bytes>;
  /** Legt fehlende Ordner an; liefert den neuen Stand. */
  schreiben(pfad: string, daten: Bytes): Promise<DateiInfo>;
  verschieben(alt: string, neu: string): Promise<DateiInfo>;
  /** In den Papierkorb (nicht endgültig löschen). */
  papierkorb(pfad: string): Promise<void>;
}

export interface Verbindung {
  server: string;
  konto: string;
  geraet: string;
  token: string;
  schluessel: string;
  name: string;
  seq: number;
  bekannt: number;
}

interface Eintrag {
  id: string;
  pfad: string;
  sha: string;
  groesse: number;
  mtime: number;
}

/** Stand beim Server; `sha === ''` heißt dort gelöscht. */
interface Basis {
  pfad: string;
  sha: string;
  seq: number;
  /** Raum, in dem die Fassung liegt (fehlt: eigenes Konto). */
  ort?: string;
  /** Blöcke der Serverfassung (für das Aufräumen). */
  bloecke?: string[];
}

export interface Zustand {
  verbindung: Verbindung | null;
  eingerichtet: boolean;
  dateien: Record<string, Eintrag>;
  basis: Record<string, Basis>;
  ausgang: Record<string, string>;
  /** Datei-ID (bzw. `id@raum`) → freigegebener Inhalts-Hash. */
  freigaben: Record<string, string>;
  aufgeraeumt?: string;
  /** Geteilte Vault-Ordner (aus den Raum-Datensätzen des eigenen Kontos). */
  raeume: Record<string, RaumJson>;
  raumStaende: Record<string, { seq: number; bekannt: number }>;
  /** Raum-Objekte für Dateien, die hier noch woanders liegen. */
  zurueck: Record<string, { raum: string; seq: number; oid: string; daten: string }>;
}

export const leererZustand = (): Zustand => ({
  verbindung: null,
  eingerichtet: false,
  dateien: {},
  basis: {},
  ausgang: {},
  freigaben: {},
  raeume: {},
  raumStaende: {},
  zurueck: {},
});

export interface Bericht {
  geholt: number;
  gesendet: number;
  konflikte: string[];
  gesperrt: Map<string, SecretTreffer[]>;
  zuGross: string[];
  defekt: number;
  neuAufgebaut: boolean;
  /** Dateien, die während des Abgleichs bearbeitet wurden (nächstes Mal). */
  uebersprungen: number;
  /** Änderungen in Ordnern mit Leserecht, als private Kopie beiseitegelegt. */
  nurLesen: string[];
  /** Geteilte Ordner ohne Zugang mehr. */
  raeumeEntfernt: string[];
}

const neuerBericht = (): Bericht => ({
  geholt: 0,
  gesendet: 0,
  konflikte: [],
  gesperrt: new Map(),
  zuGross: [],
  defekt: 0,
  neuAufgebaut: false,
  uebersprungen: 0,
  nurLesen: [],
  raeumeEntfernt: [],
});

/** Was die Einrichtung tun würde (Vorschau, nichts geändert). */
export interface Vorschau {
  hochladen: string[];
  herunterladen: string[];
  gleich: string[];
  konflikte: string[];
  gesperrt: { pfad: string; treffer: SecretTreffer[] }[];
  zuGross: string[];
  nichtGeprueft: number;
  ausgenommen: { pfad: string; grund: string }[];
  /** Dateien in geteilten Ordnern (kommen nach der Einrichtung dorthin). */
  geteilt: string[];
  bytesHoch: number;
}

const AUFRAEUMEN_ALLE = 24 * 3600 * 1000;
const MAX_ANFRAGE = 6 * 1024 * 1024;

/** Schlüssel eines Orts: eigenes Konto oder Raum. */
interface Ort {
  raum?: Raum;
  objektId(b: string, i: string): Promise<string>;
  verschluesseln(u: Umschlag): Promise<string>;
  entschluesseln(oid: string, daten: string): Promise<Umschlag | null>;
  blockId(klar: Bytes): Promise<string>;
  blockVerschluesseln(id: string, klar: Bytes): Promise<Bytes>;
  blockEntschluesseln(id: string, daten: Bytes, groesse: number): Promise<Bytes | null>;
}

export class VaultAbgleich {
  /** Umbenennungen aus Obsidian-Ereignissen seit dem letzten Durchsehen. */
  readonly umbenannt = new Map<string, string>();

  readonly fs: Dateisystem;
  readonly z: Zustand;
  readonly einstellungen: () => { maxBytes: number };
  private readonly api: (v: Verbindung) => SyncApi;
  private readonly uhr: () => Date;

  constructor(fs: Dateisystem, z: Zustand, api: (v: Verbindung) => SyncApi, einstellungen: () => { maxBytes: number }, uhr: () => Date = () => new Date()) {
    this.fs = fs;
    this.z = z;
    this.api = api;
    this.einstellungen = einstellungen;
    this.uhr = uhr;
  }

  private get v(): Verbindung {
    if (!this.z.verbindung) throw new SyncFehler('anmeldung', 'Nicht verbunden.');
    return this.z.verbindung;
  }

  private ks?: Kontoschluessel;
  private get schluessel(): Kontoschluessel {
    this.ks ??= Kontoschluessel.ausBase64(this.v.schluessel);
    return this.ks;
  }

  private ort(raum?: Raum): Ort {
    if (raum) {
      return {
        raum,
        objektId: (b, i) => raum.objektId(b, i),
        verschluesseln: (u) => raum.verschluesseln(u),
        entschluesseln: (o, d) => raum.entschluesseln(o, d),
        blockId: (k) => raum.blockId(k),
        blockVerschluesseln: (i, k) => raum.blockVerschluesseln(i, k),
        blockEntschluesseln: (i, d, g) => raum.blockEntschluesseln(i, d, g),
      };
    }
    const ks = this.schluessel;
    return {
      objektId: (b, i) => ks.objektId(b, i),
      verschluesseln: (u) => ks.verschluesseln(u),
      entschluesseln: (o, d) => ks.entschluesseln(o, d),
      blockId: (k) => ks.blockId(k),
      blockVerschluesseln: (i, k) => ks.blockVerschluesseln(i, k),
      blockEntschluesseln: (i, d, g) => ks.blockEntschluesseln(i, d, g),
    };
  }

  /** Geteilte Vault-Ordner mit eingehängtem Ordner. */
  get raeume(): Raum[] {
    return Object.values(this.z.raeume)
      .filter((r) => r.art === 'vault' && r.ordner)
      .map((r) => new Raum(r));
  }

  /** Der geteilte Ordner, unter dem [pfad] liegt. */
  raumFuer(pfad: string): Raum | undefined {
    return this.raeume.find((r) => pfad.startsWith(`${r.ordner}/`));
  }

  private vormerken(id: string): void {
    this.z.ausgang[id] = neueId();
  }

  private anPfad(pfad: string, ausser?: string): Eintrag | undefined {
    for (const e of Object.values(this.z.dateien)) if (e.pfad === pfad && e.id !== ausser) return e;
    return undefined;
  }

  // -----------------------------------------------------------------
  // Durchsehen

  /** Vergleicht den Ordner mit dem bekannten Stand und merkt Änderungen vor. */
  async durchsehen(): Promise<void> {
    const disk = (await this.fs.liste()).filter((f) => !ausnahme(f.pfad));
    const aufDisk = new Set(disk.map((f) => f.pfad));

    for (const [alt, neu] of this.umbenannt) {
      const e = this.anPfad(alt);
      if (e && aufDisk.has(neu) && !aufDisk.has(alt) && !this.anPfad(neu)) {
        e.pfad = neu;
        this.vormerken(e.id);
      }
    }
    this.umbenannt.clear();

    const nachPfad = new Map(Object.values(this.z.dateien).map((e) => [e.pfad, e]));
    const neu: DateiInfo[] = [];
    for (const f of disk) {
      const e = nachPfad.get(f.pfad);
      if (!e) {
        neu.push(f);
        continue;
      }
      if (e.mtime === f.mtime && e.groesse === f.groesse) continue;
      const sha = await sha256(await this.fs.lesen(f.pfad));
      if (sha !== e.sha) this.vormerken(e.id);
      Object.assign(e, { sha, groesse: f.groesse, mtime: f.mtime });
    }
    const verschwunden = Object.values(this.z.dateien).filter((e) => !aufDisk.has(e.pfad));
    for (const f of neu) {
      const sha = await sha256(await this.fs.lesen(f.pfad));
      // Gleicher Inhalt an neuem Ort, alter Ort weg: verschoben.
      const i = verschwunden.findIndex((e) => e.sha === sha);
      if (i >= 0) {
        const e = verschwunden.splice(i, 1)[0];
        Object.assign(e, { pfad: f.pfad, groesse: f.groesse, mtime: f.mtime });
        this.vormerken(e.id);
        continue;
      }
      const id = neueId();
      this.z.dateien[id] = { id, pfad: f.pfad, sha, groesse: f.groesse, mtime: f.mtime };
      this.vormerken(id);
    }
    for (const e of verschwunden) {
      delete this.z.dateien[e.id];
      if (this.z.basis[e.id]?.sha) this.vormerken(e.id);
      else delete this.z.ausgang[e.id];
    }
  }

  // -----------------------------------------------------------------
  // Holen

  /** Alle neuen Objekte eines Orts, entschlüsselt; `null` bei zurückgesetztem Server. */
  private async objekte(
    b: Bericht,
    raum: Raum | undefined,
    start: { seq: number; bekannt: number },
  ): Promise<{ liste: { seq: number; u: Umschlag; oid: string; daten: string }[]; bis: number } | null> {
    const api = this.api(this.v);
    const roh: { id: string; seq: number; daten: string }[] = [];
    let seit = start.seq;
    for (;;) {
      const r = await api.abrufen(seit, 500, raum?.id);
      if (r.objekte.length === 0 && roh.length === 0 && r.bis < Math.max(seit, start.bekannt)) return null;
      roh.push(...r.objekte);
      seit = r.bis;
      if (!r.mehr) break;
    }
    if (raum) {
      for (const z of Object.values(this.z.zurueck)) {
        if (z.raum === raum.id && !roh.some((o) => o.id === z.oid && o.seq >= z.seq)) roh.push({ id: z.oid, seq: z.seq, daten: z.daten });
      }
      roh.sort((x, y) => x.seq - y.seq);
    }
    const ort = this.ort(raum);
    const liste: { seq: number; u: Umschlag; oid: string; daten: string }[] = [];
    for (const o of roh) {
      const u = await ort.entschluesseln(o.id, o.daten);
      if (!u) {
        b.defekt++;
        continue;
      }
      if (u.schema > SCHEMA && u.bereich === VAULT_BEREICH) {
        throw new SyncFehler('version', 'Ein anderes Gerät nutzt eine neuere Version. Bitte das Plugin aktualisieren.');
      }
      liste.push({ seq: o.seq, u, oid: o.id, daten: o.daten });
    }
    return { liste, bis: seit };
  }

  private async holen(b: Bericht, raum?: Raum): Promise<void> {
    const st = raum ? (this.z.raumStaende[raum.id] ?? { seq: 0, bekannt: 0 }) : { seq: this.v.seq, bekannt: this.v.bekannt };
    const r = await this.objekte(b, raum, st);
    if (r === null) {
      // Server kennt weniger als wir (zurückgespielte Sicherung): neu aufbauen.
      b.neuAufgebaut = true;
      for (const [id, x] of Object.entries(this.z.basis)) {
        if (x.ort !== raum?.id) continue;
        delete this.z.basis[id];
        if (this.z.dateien[id] && (!raum || raum.schreibbar)) this.vormerken(id);
      }
      if (raum) this.z.raumStaende[raum.id] = { seq: 0, bekannt: 0 };
      else Object.assign(this.v, { seq: 0, bekannt: 0 });
      return this.holen(b, raum);
    }
    // Übersprungene Objekte (Datei wurde gerade bearbeitet) behalten ihre
    // alte Basis und werden beim nächsten Mal erneut geholt.
    let zurueckBis: number | null = null;
    for (const { seq, u, oid, daten } of r.liste) {
      if (!raum && u.bereich === 'raeume') {
        await this.raumDatensatz(u, b);
        continue;
      }
      if (u.bereich !== VAULT_BEREICH) continue;
      const id = u.id;
      if (raum && this.z.zurueck[id]?.raum === raum.id && this.z.zurueck[id].seq <= seq) delete this.z.zurueck[id];
      let d = u.daten as unknown as VaultDatei | null;
      if (d) {
        try {
          vaultPfad(d.pfad);
          if (raum) d = { ...d, pfad: `${raum.ordner}/${d.pfad}` };
        } catch {
          b.defekt++;
          continue;
        }
      }
      const basis = this.z.basis[id];
      if (basis?.ort !== raum?.id) {
        // Liegt (für uns) woanders: ein Löschvermerk hier betrifft uns nicht;
        // eine Fassung hier heißt, die Datei ist hierher gewandert. Ein Raum
        // darf aber nichts übernehmen, was hier noch woanders liegt.
        if (!d) continue;
        if (raum && (this.z.ausgang[id] || this.z.dateien[id])) {
          this.z.zurueck[id] = { raum: raum.id, seq, oid, daten };
          continue;
        }
        delete this.z.basis[id];
      } else if ((basis?.seq ?? 0) >= seq) {
        continue;
      }
      const vorher = b.uebersprungen;
      await this.einspielen(id, d, b, raum);
      if (b.uebersprungen > vorher) {
        zurueckBis ??= seq - 1;
        continue;
      }
      this.z.basis[id] = d
        ? { pfad: d.pfad, sha: d.sha256, seq, ort: raum?.id, bloecke: d.bloecke?.map((x) => x.id) }
        : { pfad: '', sha: '', seq, ort: raum?.id };
    }
    const bis = zurueckBis === null ? r.bis : Math.min(r.bis, zurueckBis);
    if (raum) this.z.raumStaende[raum.id] = { seq: bis, bekannt: Math.max(st.bekannt, r.bis) };
    else Object.assign(this.v, { seq: bis, bekannt: Math.max(st.bekannt, r.bis) });
  }

  /** Raum-Datensatz aus dem eigenen Konto (von der App geschrieben). */
  private async raumDatensatz(u: Umschlag, b: Bericht): Promise<void> {
    const j = u.daten as unknown as RaumJson | null;
    const alt = this.z.raeume[u.id];
    if (!j) {
      if (alt) await this.raumWeg(new Raum(alt), b);
      return;
    }
    if (j.art !== 'vault') return;
    this.z.raeume[u.id] = { ...j };
  }

  /** Kein Zugang mehr zu [r] (entfernt, ausgetreten, beendet). Mitglied:
   * die Dateien des Raums verschwinden (Papierkorb). Eigentümer: sie
   * bleiben und werden wieder privat. */
  private async raumWeg(r: Raum, b: Bericht): Promise<void> {
    for (const [id, x] of Object.entries(this.z.basis)) {
      if (x.ort !== r.id) continue;
      delete this.z.basis[id];
      const e = this.z.dateien[id];
      if (!e) continue;
      if (r.eigen) {
        this.vormerken(id);
      } else {
        delete this.z.ausgang[id];
        delete this.z.dateien[id];
        if (await this.fs.stat(e.pfad)) await this.fs.papierkorb(e.pfad);
      }
    }
    for (const [id, z] of Object.entries(this.z.zurueck)) if (z.raum === r.id) delete this.z.zurueck[id];
    delete this.z.raeume[r.id];
    delete this.z.raumStaende[r.id];
    b.raeumeEntfernt.push(r.j.name);
  }

  /** Schlüssel und Rechte der Räume beim Server prüfen; ohne Zugang aufräumen. */
  private async raeumePruefen(b: Bericht): Promise<void> {
    if (this.raeume.length === 0) return;
    const server = new Map((await this.api(this.v).raeume()).map((x) => [x.id, x]));
    for (const r of this.raeume) {
      const s = server.get(r.id);
      if (!s) {
        await this.raumWeg(r, b);
        continue;
      }
      if (r.eigen || !s.paket || !r.j.paar) continue;
      const k = await Raum.mitgliedPaketOeffnen(r.id, vonBase64(r.j.paar), s.paket);
      if (k) this.z.raeume[r.id] = r.mit(s.recht as RaumJson['recht'], k.epoche, k.schluessel).j;
    }
  }

  private async inhaltVon(d: VaultDatei, raum?: Raum): Promise<Bytes> {
    if (d.inhalt !== undefined) return vonBase64(d.inhalt);
    const api = this.api(this.v);
    const ort = this.ort(raum);
    const teile: Bytes[] = [];
    for (const blk of d.bloecke ?? []) {
      const klar = await ort.blockEntschluesseln(blk.id, await api.blockLesen(blk.id, raum?.id), blk.groesse);
      if (!klar) throw new SyncFehler('daten', `Ein Teil von „${d.pfad}“ ließ sich nicht entschlüsseln.`);
      teile.push(klar);
    }
    const alles = new Uint8Array(teile.reduce((n, t) => n + t.length, 0));
    let o = 0;
    for (const t of teile) {
      alles.set(t, o);
      o += t.length;
    }
    if ((await sha256(alles)) !== d.sha256) throw new SyncFehler('daten', `„${d.pfad}“ kam unvollständig an.`);
    return alles;
  }

  /** Ist die Datei seit dem Durchsehen unverändert? Sonst nicht überschreiben. */
  private async unveraendert(e: Eintrag): Promise<boolean> {
    const s = await this.fs.stat(e.pfad);
    return s !== null && s.mtime === e.mtime && s.groesse === e.groesse;
  }

  /** Macht Platz an [pfad]: eine andere Datei dort weicht. Liefert den Pfad, den [id] bekommt. */
  private async platz(id: string, d: VaultDatei): Promise<string | 'gleich'> {
    const andere = this.anPfad(d.pfad, id);
    if (!andere) return d.pfad;
    const neu = !this.z.basis[andere.id]?.sha;
    if (neu && this.z.ausgang[andere.id] && andere.sha === d.sha256) {
      // Hier neu angelegt, dort dieselbe Datei: übernehmen statt doppeln.
      delete this.z.dateien[andere.id];
      delete this.z.ausgang[andere.id];
      this.z.dateien[id] = { ...andere, id };
      return 'gleich';
    }
    const vergeben = (p: string) => !!this.anPfad(p) || p === d.pfad;
    if (neu || andere.id > id) {
      const ziel = konfliktPfad(andere.pfad, this.uhr(), this.v.name, vergeben);
      Object.assign(andere, await this.fs.verschieben(andere.pfad, ziel), { pfad: ziel });
      this.vormerken(andere.id);
      return d.pfad;
    }
    this.vormerken(id);
    return konfliktPfad(d.pfad, this.uhr(), this.v.name, vergeben);
  }

  /** Schreibt die Serverfassung [d] für [id] auf die Platte. */
  private async anwenden(id: string, d: VaultDatei | null, b: Bericht, quelle?: Raum): Promise<void> {
    const hier = this.z.dateien[id];
    if (!d) {
      if (hier) {
        if (!(await this.unveraendert(hier))) {
          b.uebersprungen++;
          return;
        }
        await this.fs.papierkorb(hier.pfad);
        delete this.z.dateien[id];
      }
      return;
    }
    if (ausnahme(d.pfad)) return;
    if (hier && !(await this.unveraendert(hier))) {
      b.uebersprungen++;
      return;
    }
    const ziel = await this.platz(id, d);
    if (ziel === 'gleich') {
      if (hier) await this.fs.papierkorb(hier.pfad);
      return;
    }
    let info: DateiInfo;
    if (hier && hier.sha === d.sha256) {
      if (hier.pfad === ziel) return;
      info = await this.fs.verschieben(hier.pfad, ziel);
    } else {
      info = await this.fs.schreiben(ziel, await this.inhaltVon(d, quelle));
      if (hier && hier.pfad !== ziel) await this.fs.papierkorb(hier.pfad);
    }
    this.z.dateien[id] = { id, pfad: ziel, sha: d.sha256, groesse: info.groesse, mtime: info.mtime };
  }

  private async einspielen(id: string, d: VaultDatei | null, b: Bericht, quelle?: Raum): Promise<void> {
    const basis = this.z.basis[id];
    const hier = this.z.dateien[id];
    if (!this.z.ausgang[id]) {
      b.geholt++;
      return this.anwenden(id, d, b, quelle);
    }
    if (!d) return; // dort gelöscht, hier geändert: Änderung bleibt
    if (!hier) {
      // hier gelöscht, dort geändert: kommt zurück
      delete this.z.ausgang[id];
      b.geholt++;
      return this.anwenden(id, d, b, quelle);
    }
    const bekannt = basis?.sha ? basis : undefined;
    const hierPfad = !bekannt || hier.pfad !== bekannt.pfad;
    const hierInhalt = !bekannt || hier.sha !== bekannt.sha;
    const dortPfad = !bekannt || d.pfad !== bekannt.pfad;
    const pfad = hierPfad && !dortPfad ? hier.pfad : d.pfad;
    b.geholt++;
    if (!(await this.unveraendert(hier))) {
      b.uebersprungen++;
      return;
    }
    if (hierInhalt && hier.sha !== d.sha256 && (!bekannt || d.sha256 !== bekannt.sha)) {
      // Beide Inhalte geändert: eigene Fassung wird Konfliktkopie.
      const ziel = konfliktPfad(pfad, this.uhr(), this.v.name, (p) => !!this.anPfad(p, id) || p === pfad);
      const kopie = neueId();
      const info = await this.fs.verschieben(hier.pfad, ziel);
      this.z.dateien[kopie] = { id: kopie, pfad: ziel, sha: hier.sha, groesse: info.groesse, mtime: info.mtime };
      this.vormerken(kopie);
      delete this.z.dateien[id];
      b.konflikte.push(ziel);
      if (pfad === d.pfad) delete this.z.ausgang[id];
      return this.anwenden(id, { ...d, pfad }, b, quelle);
    }
    if (hierInhalt && hier.sha !== d.sha256) {
      // Eigener Inhalt gilt, Pfad wie zusammengeführt.
      if (hier.pfad !== pfad && !this.anPfad(pfad, id)) {
        Object.assign(hier, await this.fs.verschieben(hier.pfad, pfad), { pfad });
      }
      return;
    }
    if (pfad === d.pfad) delete this.z.ausgang[id];
    return this.anwenden(id, { ...d, pfad }, b, quelle);
  }

  // -----------------------------------------------------------------
  // Senden

  static freigabeSchluessel(id: string, raum?: string): string {
    return raum ? `${id}@${raum}` : id;
  }

  /** Änderung in einem Ordner mit Leserecht: beiseitelegen, Fassung des
   * Raums wiederherstellen (beim nächsten Holen). */
  private async nurLesen(id: string, r: Raum, b: Bericht): Promise<void> {
    const e = this.z.dateien[id];
    delete this.z.ausgang[id];
    if (e) {
      const basisPfad = `Eigene Änderungen/${r.j.name.replace(/\//g, '-')}/${e.pfad.slice(r.ordner!.length + 1)}`;
      const frei = this.anPfad(basisPfad) ? konfliktPfad(basisPfad, this.uhr(), this.v.name, (p) => !!this.anPfad(p)) : basisPfad;
      const info = await this.fs.verschieben(e.pfad, frei);
      delete this.z.dateien[id];
      const kopie = neueId();
      this.z.dateien[kopie] = { id: kopie, pfad: frei, sha: e.sha, groesse: info.groesse, mtime: info.mtime };
      this.vormerken(kopie);
      b.nurLesen.push(frei);
    }
    if (this.z.basis[id]) {
      delete this.z.basis[id];
      // Fassung des Raums erneut holen.
      this.z.raumStaende[r.id] = { seq: 0, bekannt: this.z.raumStaende[r.id]?.bekannt ?? 0 };
    }
  }

  private async senden(b: Bericht): Promise<boolean> {
    const api = this.api(this.v);
    const max = this.einstellungen().maxBytes;
    type Teil = { id: string; basis: number; aenderung: string; daten: string; pfad: string; sha: string; lokal: string; bloecke?: string[]; ort?: string; leer: boolean };
    const weg = new Map<string | undefined, Teil[]>();
    const hin = new Map<string | undefined, Teil[]>();
    const bloecke = new Map<string | undefined, Map<string, Bytes>>();
    const raeume = new Map(this.raeume.map((r) => [r.id, r]));
    // Liegt eine Datei laut Pfad jetzt woanders als beim Server (Ordner
    // geteilt oder Freigabe beendet), muss sie umziehen.
    for (const e of Object.values(this.z.dateien)) {
      const basis = this.z.basis[e.id];
      const zr = this.raumFuer(e.pfad);
      if (basis?.sha && basis.ort !== zr?.id && !this.z.ausgang[e.id] && (!zr || zr.schreibbar)) this.vormerken(e.id);
    }
    for (const [id, aenderung] of Object.entries(this.z.ausgang)) {
      const e = this.z.dateien[id];
      const basis = this.z.basis[id];
      const alt = basis ? basis.ort : undefined;
      const zr = e ? this.raumFuer(e.pfad) : alt ? raeume.get(alt) : undefined;
      const ziel = e ? zr?.id : alt;
      if (ziel && !zr) {
        // Raum unbekannt (entfernt): nichts senden.
        delete this.z.ausgang[id];
        continue;
      }
      if (zr && !zr.schreibbar) {
        await this.nurLesen(id, zr, b);
        continue;
      }
      if (!e) {
        if (!basis?.sha) {
          delete this.z.ausgang[id];
          continue;
        }
        const ort = this.ort(zr);
        const daten = await ort.verschluesseln({ bereich: VAULT_BEREICH, id, schema: SCHEMA, daten: null });
        const t: Teil = { id: await ort.objektId(VAULT_BEREICH, id), basis: basis.seq, aenderung, daten, pfad: '', sha: '', lokal: id, ort: ziel, leer: true };
        hin.set(ziel, [...(hin.get(ziel) ?? []), t]);
        continue;
      }
      if (e.groesse > max) {
        b.zuGross.push(e.pfad);
        continue;
      }
      if (!(await this.unveraendert(e))) {
        b.uebersprungen++;
        continue;
      }
      const inhalt = await this.fs.lesen(e.pfad);
      if ((await sha256(inhalt)) !== e.sha) {
        b.uebersprungen++;
        continue;
      }
      const ortWechsel = !!basis?.sha && alt !== ziel;
      if (basis?.sha !== e.sha || (ziel && (ortWechsel || !basis?.sha))) {
        // Neuer Inhalt oder neu in einem geteilten Ordner: auf Secrets prüfen.
        const t = pruefen(inhalt);
        if (t && t.length > 0 && this.z.freigaben[VaultAbgleich.freigabeSchluessel(id, ziel)] !== e.sha) {
          b.gesperrt.set(id, t);
          continue;
        }
      }
      const ort = this.ort(zr);
      const neueBloecke = bloecke.get(ziel) ?? new Map<string, Bytes>();
      bloecke.set(ziel, neueBloecke);
      const d = await this.schluessel.vaultDatei(id, zr ? e.pfad.slice(zr.ordner!.length + 1) : e.pfad, inhalt, new Date(e.mtime || this.uhr().getTime()), neueBloecke, ort.blockId);
      const daten = await ort.verschluesseln({ bereich: VAULT_BEREICH, id, schema: SCHEMA, daten: d as unknown as Record<string, unknown> });
      if (ortWechsel) {
        const ar = alt ? raeume.get(alt) : undefined;
        if (!alt || ar?.schreibbar) {
          const ao = this.ort(ar);
          const leer = await ao.verschluesseln({ bereich: VAULT_BEREICH, id, schema: SCHEMA, daten: null });
          weg.set(alt, [...(weg.get(alt) ?? []), { id: await ao.objektId(VAULT_BEREICH, id), basis: basis!.seq, aenderung, daten: leer, pfad: '', sha: '', lokal: id, ort: alt, leer: true }]);
        }
      }
      const t: Teil = {
        id: await ort.objektId(VAULT_BEREICH, id),
        basis: basis && !ortWechsel && alt === ziel ? basis.seq : 0,
        aenderung,
        daten,
        pfad: e.pfad,
        sha: e.sha,
        lokal: id,
        bloecke: d.bloecke?.map((x) => x.id),
        ort: ziel,
        leer: false,
      };
      hin.set(ziel, [...(hin.get(ziel) ?? []), t]);
    }
    if (hin.size === 0 && weg.size === 0) return false;

    for (const [ort, m] of bloecke) {
      if (m.size === 0) continue;
      const o = this.ort(ort ? raeume.get(ort) : undefined);
      for (const bid of await api.bloeckeFehlend([...m.keys()], ort)) await api.blockSchreiben(bid, await o.blockVerschluesseln(bid, m.get(bid)!), ort);
    }

    let konflikt = false;
    const gescheitert = new Set<string>();
    for (const [ort, liste] of weg) {
      for (const r of await api.schreiben(liste.map(({ id, basis, aenderung, daten }) => ({ id, basis, aenderung, daten })), ort)) {
        if (r.ok) continue;
        konflikt = true;
        const t = liste.find((x) => x.id === r.id);
        if (t) gescheitert.add(t.lokal);
      }
    }
    for (const [ort, alle] of hin) {
      const liste = alle.filter((t) => !gescheitert.has(t.lokal));
      const o = this.ort(ort ? raeume.get(ort) : undefined);
      let gruppe: Teil[] = [];
      let groesse = 0;
      const abschicken = async (): Promise<void> => {
        if (gruppe.length === 0) return;
        const zuId = new Map(gruppe.map((t) => [t.id, t]));
        let ergebnisse = await api.schreiben(gruppe.map(({ id, basis, aenderung, daten }) => ({ id, basis, aenderung, daten })), ort);
        // Zurück an einen Ort, an dem nur noch ein Löschvermerk liegt: der gilt als Basis.
        const nochmal: Teil[] = [];
        for (const r of ergebnisse) {
          const t = zuId.get(r.id);
          if (r.ok || !t || t.basis !== 0 || !r.daten) continue;
          const dort = await o.entschluesseln(r.id, r.daten);
          if (dort && dort.daten === null) nochmal.push({ ...t, basis: r.seq });
        }
        if (nochmal.length > 0) {
          const zweite = new Map((await api.schreiben(nochmal.map(({ id, basis, aenderung, daten }) => ({ id, basis, aenderung, daten })), ort)).map((r) => [r.id, r]));
          ergebnisse = ergebnisse.map((r) => zweite.get(r.id) ?? r);
        }
        for (const r of ergebnisse) {
          const t = zuId.get(r.id);
          if (!t) continue;
          if (!r.ok) {
            konflikt = true;
            continue;
          }
          b.gesendet++;
          this.z.basis[t.lokal] = t.leer ? { pfad: '', sha: '', seq: r.seq, ort } : { pfad: t.pfad, sha: t.sha, seq: r.seq, ort, bloecke: t.bloecke };
          if (this.z.ausgang[t.lokal] === t.aenderung) delete this.z.ausgang[t.lokal];
          if (ort) {
            const s = this.z.raumStaende[ort] ?? { seq: 0, bekannt: 0 };
            if (r.seq > s.bekannt) this.z.raumStaende[ort] = { ...s, bekannt: r.seq };
          } else if (r.seq > this.v.bekannt) this.v.bekannt = r.seq;
        }
        gruppe = [];
        groesse = 0;
      };
      for (const t of liste) {
        if (gruppe.length >= 200 || groesse + t.daten.length > MAX_ANFRAGE) await abschicken();
        gruppe.push(t);
        groesse += t.daten.length;
      }
      await abschicken();
    }
    return konflikt;
  }

  private async aufraeumen(b: Bericht): Promise<void> {
    if (b.defekt > 0) return;
    const jetzt = this.uhr().getTime();
    if (this.z.aufgeraeumt && jetzt - Date.parse(this.z.aufgeraeumt) < AUFRAEUMEN_ALLE) return;
    const behalten = new Map<string | undefined, Set<string>>();
    for (const x of Object.values(this.z.basis)) {
      const s = behalten.get(x.ort) ?? new Set<string>();
      behalten.set(x.ort, s);
      for (const id of x.bloecke ?? []) s.add(id);
    }
    if (behalten.size === 0 && !this.z.aufgeraeumt) return;
    try {
      const api = this.api(this.v);
      await api.bloeckeAufraeumen([...(behalten.get(undefined) ?? [])]);
      for (const r of this.raeume) if (r.eigen) await api.bloeckeAufraeumen([...(behalten.get(r.id) ?? [])], r.id);
      this.z.aufgeraeumt = new Date(jetzt).toISOString();
    } catch {
      // Nebensache; der Abgleich war erfolgreich.
    }
  }

  // -----------------------------------------------------------------

  /** Ein vollständiger Abgleich. */
  async abgleichen(): Promise<Bericht> {
    const b = neuerBericht();
    if (!this.z.eingerichtet) throw new SyncFehler('anmeldung', 'Der Vault-Sync ist noch nicht eingerichtet.');
    await this.durchsehen();
    for (let runde = 0; runde < 4; runde++) {
      await this.holen(b);
      await this.raeumePruefen(b);
      for (const r of this.raeume) {
        try {
          await this.holen(b, r);
        } catch (e) {
          // Zugang entzogen, bevor die App den Raum-Datensatz entfernt hat.
          if (e instanceof SyncFehler && e.art === 'nichtGefunden') await this.raumWeg(r, b);
          else throw e;
        }
      }
      if (!(await this.senden(b))) break;
    }
    await this.aufraeumen(b);
    return b;
  }

  // -----------------------------------------------------------------
  // Einrichtung

  /** Was die Einrichtung tun würde; ändert nichts außer dem Durchsehen. */
  async vorschau(): Promise<Vorschau> {
    await this.durchsehen();
    const b = neuerBericht();
    const r = (await this.objekte(b, undefined, { seq: 0, bekannt: 0 })) ?? { liste: [], bis: 0 };
    const dort = new Map<string, VaultDatei>();
    const mounts: string[] = [];
    for (const { u } of r.liste) {
      if (u.bereich === 'raeume') {
        const j = u.daten as unknown as RaumJson | null;
        if (j?.art === 'vault' && j.ordner) mounts.push(j.ordner);
        continue;
      }
      if (u.bereich !== VAULT_BEREICH) continue;
      if (u.daten) dort.set(u.id, u.daten as unknown as VaultDatei);
      else dort.delete(u.id);
    }
    const dortNachPfad = new Map([...dort.values()].map((d) => [d.pfad, d]));
    const p: Vorschau = { hochladen: [], herunterladen: [], gleich: [], konflikte: [], gesperrt: [], zuGross: [], nichtGeprueft: 0, ausgenommen: [], geteilt: [], bytesHoch: 0 };
    const max = this.einstellungen().maxBytes;
    for (const f of await this.fs.liste()) {
      const grund = ausnahme(f.pfad);
      if (grund) p.ausgenommen.push({ pfad: f.pfad, grund });
    }
    const hierPfade = new Set<string>();
    for (const e of Object.values(this.z.dateien)) {
      hierPfade.add(e.pfad);
      if (mounts.some((m) => e.pfad.startsWith(`${m}/`))) {
        p.geteilt.push(e.pfad);
        continue;
      }
      const d = dortNachPfad.get(e.pfad);
      if (d && d.sha256 === e.sha) {
        p.gleich.push(e.pfad);
        continue;
      }
      if (d) p.konflikte.push(e.pfad);
      if (e.groesse > max) {
        p.zuGross.push(e.pfad);
        continue;
      }
      const t = e.groesse > 10 * 1024 * 1024 ? null : pruefen(await this.fs.lesen(e.pfad));
      if (t === null) p.nichtGeprueft++;
      else if (t.length > 0 && this.z.freigaben[e.id] !== e.sha) {
        p.gesperrt.push({ pfad: e.pfad, treffer: t });
        continue;
      }
      p.hochladen.push(e.pfad);
      p.bytesHoch += e.groesse;
    }
    for (const d of dort.values()) if (!hierPfade.has(d.pfad) && !ausnahme(d.pfad)) p.herunterladen.push(d.pfad);
    for (const l of Object.values(p)) if (Array.isArray(l)) l.sort((a, c) => String(a.pfad ?? a).localeCompare(String(c.pfad ?? c)));
    return p;
  }

  /** Freigabe einer Datei trotz Secret-Treffer, nur für diesen Inhalt am jetzigen Ort. */
  freigeben(pfad: string): void {
    const e = this.anPfad(pfad);
    if (e) this.z.freigaben[VaultAbgleich.freigabeSchluessel(e.id, this.raumFuer(pfad)?.id)] = e.sha;
  }

  idVon(pfad: string): string | undefined {
    return this.anPfad(pfad)?.id;
  }

  pfadVon(id: string): string | undefined {
    return this.z.dateien[id]?.pfad;
  }

  /** Zahl der noch nicht gesendeten Änderungen. */
  get ausstehend(): number {
    return Object.keys(this.z.ausgang).length;
  }
}
