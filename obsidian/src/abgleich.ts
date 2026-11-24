// Abgleich des Vault-Ordners mit dem Server (Regeln: protokoll/VAULT.md).
//
// Ablauf: Ordner durchsehen (neue, geänderte, verschobene, gelöschte
// Dateien) → alles Neue vom Server holen und einspielen → Ausstehendes
// senden; meldet der Server einen Konflikt, wiederholen.
//
// Vor der ausdrücklichen Einrichtung (Vorschau bestätigt) wird weder
// geschrieben noch hochgeladen.

import { SyncApi, SyncFehler } from './api.ts';
import { sha256, vonBase64 } from './krypto.ts';
import { ausnahme, Kontoschluessel, konfliktPfad, neueId, SCHEMA, VAULT_BEREICH, type VaultDatei, vaultPfad } from './protokoll.ts';
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
  /** Blöcke der Serverfassung (für das Aufräumen). */
  bloecke?: string[];
}

export interface Zustand {
  verbindung: Verbindung | null;
  eingerichtet: boolean;
  dateien: Record<string, Eintrag>;
  basis: Record<string, Basis>;
  ausgang: Record<string, string>;
  freigaben: Record<string, string>;
  aufgeraeumt?: string;
}

export const leererZustand = (): Zustand => ({ verbindung: null, eingerichtet: false, dateien: {}, basis: {}, ausgang: {}, freigaben: {} });

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
  bytesHoch: number;
}

const AUFRAEUMEN_ALLE = 24 * 3600 * 1000;
const MAX_ANFRAGE = 6 * 1024 * 1024;

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

  private async alleObjekte(b: Bericht): Promise<{ seq: number; d: VaultDatei | null; id: string }[] | null> {
    const v = this.v;
    const api = this.api(v);
    const roh: { id: string; seq: number; daten: string }[] = [];
    let seit = v.seq;
    for (;;) {
      const r = await api.abrufen(seit, 500);
      if (r.objekte.length === 0 && roh.length === 0 && r.bis < Math.max(seit, v.bekannt)) return null;
      roh.push(...r.objekte);
      seit = r.bis;
      if (!r.mehr) break;
    }
    const liste: { seq: number; d: VaultDatei | null; id: string }[] = [];
    for (const o of roh) {
      const u = await this.schluessel.entschluesseln(o.id, o.daten);
      if (!u) {
        b.defekt++;
        continue;
      }
      if (u.bereich !== VAULT_BEREICH) continue;
      if (u.schema > SCHEMA) throw new SyncFehler('version', 'Ein anderes Gerät nutzt eine neuere Version. Bitte das Plugin aktualisieren.');
      const d = u.daten as VaultDatei | null;
      if (d) {
        try {
          vaultPfad(d.pfad);
        } catch {
          b.defekt++;
          continue;
        }
      }
      liste.push({ seq: o.seq, d, id: u.id });
    }
    v.seq = seit;
    v.bekannt = Math.max(v.bekannt, seit);
    return liste;
  }

  private async holen(b: Bericht): Promise<void> {
    const seqVorher = this.v.seq;
    const liste = await this.alleObjekte(b);
    if (liste === null) {
      // Server kennt weniger als wir (zurückgespielte Sicherung): neu aufbauen.
      b.neuAufgebaut = true;
      this.z.basis = {};
      for (const id of Object.keys(this.z.dateien)) this.vormerken(id);
      this.v.seq = 0;
      this.v.bekannt = 0;
      return this.holen(b);
    }
    // Übersprungene Objekte (Datei wurde gerade bearbeitet) behalten ihre
    // alte Basis und werden beim nächsten Mal erneut geholt.
    let zurueck: number | null = null;
    try {
      for (const { seq, d, id } of liste) {
        if ((this.z.basis[id]?.seq ?? 0) >= seq) continue;
        const vorher = b.uebersprungen;
        await this.einspielen(id, d, b);
        if (b.uebersprungen > vorher) {
          zurueck ??= seq - 1;
          continue;
        }
        this.z.basis[id] = d ? { pfad: d.pfad, sha: d.sha256, seq, bloecke: d.bloecke?.map((x) => x.id) } : { pfad: '', sha: '', seq };
      }
    } catch (e) {
      this.v.seq = seqVorher;
      throw e;
    }
    if (zurueck !== null) this.v.seq = Math.min(this.v.seq, zurueck);
  }

  private async inhaltVon(d: VaultDatei): Promise<Bytes> {
    if (d.inhalt !== undefined) return vonBase64(d.inhalt);
    const api = this.api(this.v);
    const teile: Bytes[] = [];
    for (const blk of d.bloecke ?? []) {
      const klar = await this.schluessel.blockEntschluesseln(blk.id, await api.blockLesen(blk.id), blk.groesse);
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
  private async anwenden(id: string, d: VaultDatei | null, b: Bericht): Promise<void> {
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
      info = await this.fs.schreiben(ziel, await this.inhaltVon(d));
      if (hier && hier.pfad !== ziel) await this.fs.papierkorb(hier.pfad);
    }
    this.z.dateien[id] = { id, pfad: ziel, sha: d.sha256, groesse: info.groesse, mtime: info.mtime };
  }

  private async einspielen(id: string, d: VaultDatei | null, b: Bericht): Promise<void> {
    const basis = this.z.basis[id];
    const hier = this.z.dateien[id];
    if (!this.z.ausgang[id]) {
      b.geholt++;
      return this.anwenden(id, d, b);
    }
    if (!d) return; // dort gelöscht, hier geändert: Änderung bleibt
    if (!hier) {
      // hier gelöscht, dort geändert: kommt zurück
      delete this.z.ausgang[id];
      b.geholt++;
      return this.anwenden(id, d, b);
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
      return this.anwenden(id, { ...d, pfad }, b);
    }
    if (hierInhalt && hier.sha !== d.sha256) {
      // Eigener Inhalt gilt, Pfad wie zusammengeführt.
      if (hier.pfad !== pfad && !this.anPfad(pfad, id)) {
        Object.assign(hier, await this.fs.verschieben(hier.pfad, pfad), { pfad });
      }
      return;
    }
    if (pfad === d.pfad) delete this.z.ausgang[id];
    return this.anwenden(id, { ...d, pfad }, b);
  }

  // -----------------------------------------------------------------
  // Senden

  private async senden(b: Bericht): Promise<boolean> {
    const api = this.api(this.v);
    const max = this.einstellungen().maxBytes;
    type Teil = { id: string; basis: number; aenderung: string; daten: string; pfad: string; sha: string; lokal: string; bloecke?: string[] };
    const bereit: Teil[] = [];
    const bloecke = new Map<string, Bytes>();
    for (const [id, aenderung] of Object.entries(this.z.ausgang)) {
      const e = this.z.dateien[id];
      const basis = this.z.basis[id];
      const oid = await this.schluessel.objektId(VAULT_BEREICH, id);
      if (!e) {
        if (!basis?.sha) {
          delete this.z.ausgang[id];
          continue;
        }
        const daten = await this.schluessel.verschluesseln({ bereich: VAULT_BEREICH, id, schema: SCHEMA, daten: null });
        bereit.push({ id: oid, basis: basis.seq, aenderung, daten, pfad: '', sha: '', lokal: id });
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
      if (basis?.sha !== e.sha) {
        const t = pruefen(inhalt);
        if (t && t.length > 0 && this.z.freigaben[id] !== e.sha) {
          b.gesperrt.set(id, t);
          continue;
        }
      }
      const d = await this.schluessel.vaultDatei(id, e.pfad, inhalt, new Date(e.mtime || this.uhr().getTime()), bloecke);
      const daten = await this.schluessel.verschluesseln({ bereich: VAULT_BEREICH, id, schema: SCHEMA, daten: d as unknown as Record<string, unknown> });
      bereit.push({ id: oid, basis: basis?.seq ?? 0, aenderung, daten, pfad: e.pfad, sha: e.sha, lokal: id, bloecke: d.bloecke?.map((x) => x.id) });
    }
    if (bereit.length === 0) return false;

    if (bloecke.size > 0) {
      for (const bid of await api.bloeckeFehlend([...bloecke.keys()])) {
        await api.blockSchreiben(bid, await this.schluessel.blockVerschluesseln(bid, bloecke.get(bid)!));
      }
    }

    const zuId = new Map(bereit.map((t) => [t.id, t]));

    let konflikt = false;
    let gruppe: Teil[] = [];
    let groesse = 0;
    const abschicken = async () => {
      if (gruppe.length === 0) return;
      const ergebnisse = await api.schreiben(gruppe.map(({ id, basis, aenderung, daten }) => ({ id, basis, aenderung, daten })));
      for (const r of ergebnisse) {
        const t = zuId.get(r.id);
        if (!t) continue;
        if (!r.ok) {
          konflikt = true;
          continue;
        }
        b.gesendet++;
        this.z.basis[t.lokal] = { pfad: t.pfad, sha: t.sha, seq: r.seq, bloecke: t.bloecke };
        if (this.z.ausgang[t.lokal] === t.aenderung) delete this.z.ausgang[t.lokal];
        if (r.seq > this.v.bekannt) this.v.bekannt = r.seq;
      }
      gruppe = [];
      groesse = 0;
    };
    for (const t of bereit) {
      if (gruppe.length >= 200 || groesse + t.daten.length > MAX_ANFRAGE) await abschicken();
      gruppe.push(t);
      groesse += t.daten.length;
    }
    await abschicken();
    return konflikt;
  }

  private async aufraeumen(b: Bericht): Promise<void> {
    if (b.defekt > 0) return;
    const jetzt = this.uhr().getTime();
    if (this.z.aufgeraeumt && jetzt - Date.parse(this.z.aufgeraeumt) < AUFRAEUMEN_ALLE) return;
    // Alle Blöcke der Dateien beim Server (laut Basis).
    const behalten = new Set<string>();
    for (const x of Object.values(this.z.basis)) for (const id of x.bloecke ?? []) behalten.add(id);
    if (behalten.size === 0 && !this.z.aufgeraeumt) return;
    try {
      await this.api(this.v).bloeckeAufraeumen([...behalten]);
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
    const v = this.v;
    const seq = v.seq;
    const bekannt = v.bekannt;
    v.seq = 0;
    v.bekannt = 0;
    const liste = (await this.alleObjekte(b)) ?? [];
    v.seq = seq;
    v.bekannt = bekannt;
    const dort = new Map<string, VaultDatei>();
    for (const { d, id } of liste) {
      if (d) dort.set(id, d);
      else dort.delete(id);
    }
    const dortNachPfad = new Map([...dort.values()].map((d) => [d.pfad, d]));
    const p: Vorschau = { hochladen: [], herunterladen: [], gleich: [], konflikte: [], gesperrt: [], zuGross: [], nichtGeprueft: 0, ausgenommen: [], bytesHoch: 0 };
    const max = this.einstellungen().maxBytes;
    for (const f of await this.fs.liste()) {
      const grund = ausnahme(f.pfad);
      if (grund) p.ausgenommen.push({ pfad: f.pfad, grund });
    }
    const hierPfade = new Set<string>();
    for (const e of Object.values(this.z.dateien)) {
      hierPfade.add(e.pfad);
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

  /** Freigabe einer Datei trotz Secret-Treffer, nur für diesen Inhalt. */
  freigeben(pfad: string): void {
    const e = this.anPfad(pfad);
    if (e) this.z.freigaben[e.id] = e.sha;
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

