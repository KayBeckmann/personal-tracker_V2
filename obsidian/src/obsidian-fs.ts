// Dateisystem des Abgleichs über die Obsidian-API (Desktop und Mobil).
// Sichtbare Dateien laufen über `Vault` (Editoren bekommen Änderungen
// mit), versteckte wie `.obsidian/` über den Adapter.

import { normalizePath, TFile, type App } from 'obsidian';
import type { DateiInfo, Dateisystem } from './abgleich.ts';

type Bytes = Uint8Array<ArrayBuffer>;

export class ObsidianFs implements Dateisystem {
  private readonly app: App;
  constructor(app: App) {
    this.app = app;
  }

  private get adapter() {
    return this.app.vault.adapter;
  }

  private datei(pfad: string): TFile | null {
    return this.app.vault.getFileByPath(normalizePath(pfad));
  }

  async liste(): Promise<DateiInfo[]> {
    const out: DateiInfo[] = [];
    const besuchen = async (ordner: string): Promise<void> => {
      const l = await this.adapter.list(ordner);
      for (const f of l.files) {
        const pfad = f.replace(/^\/+/, '');
        const t = this.datei(pfad);
        if (t) {
          out.push({ pfad, groesse: t.stat.size, mtime: t.stat.mtime });
        } else {
          const s = await this.adapter.stat(f);
          if (s?.type === 'file') out.push({ pfad, groesse: s.size, mtime: s.mtime });
        }
      }
      for (const o of l.folders) await besuchen(o);
    };
    await besuchen('/');
    return out;
  }

  async stat(pfad: string): Promise<DateiInfo | null> {
    const s = await this.adapter.stat(normalizePath(pfad));
    return s?.type === 'file' ? { pfad, groesse: s.size, mtime: s.mtime } : null;
  }

  async lesen(pfad: string): Promise<Bytes> {
    return new Uint8Array(await this.adapter.readBinary(normalizePath(pfad)));
  }

  private async ordnerFuer(pfad: string): Promise<void> {
    const teile = pfad.split('/').slice(0, -1);
    for (let i = 1; i <= teile.length; i++) {
      const o = teile.slice(0, i).join('/');
      if (!(await this.adapter.exists(o))) await this.adapter.mkdir(o);
    }
  }

  async schreiben(pfad: string, daten: Bytes): Promise<DateiInfo> {
    const p = normalizePath(pfad);
    const t = this.datei(p);
    const puffer = daten.buffer.slice(daten.byteOffset, daten.byteOffset + daten.byteLength);
    if (t) {
      await this.app.vault.modifyBinary(t, puffer);
    } else {
      await this.ordnerFuer(p);
      if (p.split('/').some((x) => x.startsWith('.'))) await this.adapter.writeBinary(p, puffer);
      else await this.app.vault.createBinary(p, puffer);
    }
    return (await this.stat(p))!;
  }

  async verschieben(alt: string, neu: string): Promise<DateiInfo> {
    const p = normalizePath(neu);
    await this.ordnerFuer(p);
    const t = this.datei(alt);
    if (t) await this.app.vault.rename(t, p);
    else await this.adapter.rename(normalizePath(alt), p);
    return (await this.stat(p))!;
  }

  async papierkorb(pfad: string): Promise<void> {
    const t = this.datei(pfad);
    if (t) await this.app.vault.trash(t, false);
    else await this.adapter.trashLocal(normalizePath(pfad));
  }
}
