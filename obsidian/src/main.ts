// Obsidian-Plugin „Personal Tracker Sync“: gleicht den ganzen Vault
// Ende-zu-Ende-verschlüsselt mit dem Sync-Server des Personal Trackers ab.
// Verbunden wird per Kopplungscode aus der App; vor dem ersten Hochladen
// zeigt eine Vorschau alle Pfade, Secret-Treffer und Ausnahmen.

import { App, Modal, Notice, Plugin, PluginSettingTab, requestUrl, Setting, normalizePath } from 'obsidian';

import { VaultAbgleich, leererZustand, type Bericht, type Verbindung, type Vorschau, type Zustand } from './abgleich.ts';
import { SyncApi, SyncFehler, type Transport } from './api.ts';
import { ObsidianFs } from './obsidian-fs.ts';
import { zufall, hex } from './krypto.ts';
import { koppeln } from './verbinden.ts';
import { ausnahme } from './protokoll.ts';
import type { SecretTreffer } from './secrets.ts';
import { zip } from './zip.ts';

interface Einstellungen {
  server: string;
  maxMiB: number;
  automatisch: boolean;
}

const STANDARD: Einstellungen = { server: '', maxMiB: 100, automatisch: true };

const obsidianTransport: Transport = async ({ url, methode, kopf, body }) => {
  const r = await requestUrl({
    url,
    method: methode,
    headers: kopf,
    contentType: kopf['content-type'],
    body: body instanceof Uint8Array ? body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength) : body,
    throw: false,
  });
  const bytes = new Uint8Array(r.arrayBuffer);
  return { status: r.status, bytes, text: new TextDecoder().decode(bytes) };
};

export default class PersonalTrackerSync extends Plugin {
  einstellungen: Einstellungen = { ...STANDARD };
  z: Zustand = leererZustand();
  abgleich!: VaultAbgleich;
  status = '';
  letzter?: Bericht;
  fehler?: string;
  private laufend: Promise<void> | null = null;
  private nochmal = false;
  private zeitgeber: number | null = null;
  private statusLeiste!: HTMLElement;

  async onload(): Promise<void> {
    this.einstellungen = { ...STANDARD, ...((await this.loadData()) ?? {}) };
    this.z = this.zustandLaden();
    this.abgleich = this.neuerAbgleich();
    this.statusLeiste = this.addStatusBarItem();
    this.statusZeigen();
    this.addSettingTab(new EinstellungenSeite(this.app, this));
    this.addRibbonIcon('refresh-cw', 'Personal Tracker: jetzt abgleichen', () => void this.abgleichen(true));
    this.addCommand({ id: 'jetzt-abgleichen', name: 'Jetzt abgleichen', callback: () => void this.abgleichen(true) });
    this.addCommand({ id: 'einrichten', name: 'Vorschau und Einrichtung', callback: () => void this.vorschauOeffnen() });

    this.registerEvent(this.app.vault.on('rename', (f, alt) => {
      this.abgleich.umbenannt.set(alt, f.path);
      this.bald();
    }));
    for (const ereignis of ['modify', 'create', 'delete'] as const) {
      this.registerEvent(this.app.vault.on(ereignis as 'modify', () => this.bald()));
    }
    this.app.workspace.onLayoutReady(() => void this.abgleichen(false));
    this.registerInterval(window.setInterval(() => void this.abgleichen(false), 5 * 60 * 1000));
  }

  onunload(): void {
    if (this.zeitgeber !== null) window.clearTimeout(this.zeitgeber);
  }

  // ---------------------------------------------------------------
  // Zustand: Verbindungsgeheimnisse in der Schlüsselablage von Obsidian,
  // der Rest gerätebezogen im localStorage dieses Vaults. Nichts davon
  // liegt im Vault-Ordner (und damit in keinem anderen Sync).

  private get vaultKennung(): string {
    let k = this.app.loadLocalStorage('ptv2-sync-kennung') as string | null;
    if (!k) {
      k = hex(zufall(8));
      this.app.saveLocalStorage('ptv2-sync-kennung', k);
    }
    return k;
  }

  private zustandLaden(): Zustand {
    const roh = this.app.loadLocalStorage('ptv2-sync-zustand') as string | null;
    const z: Zustand = roh ? { ...leererZustand(), ...JSON.parse(roh) } : leererZustand();
    if (z.verbindung) {
      const token = this.app.secretStorage.getSecret(`ptv2-token-${this.vaultKennung}`);
      const schluessel = this.app.secretStorage.getSecret(`ptv2-schluessel-${this.vaultKennung}`);
      if (!token || !schluessel) return leererZustand();
      z.verbindung = { ...z.verbindung, token, schluessel };
      // Raumschlüssel liegen wie Token und Kontoschlüssel in der Schlüsselablage.
      z.raeume = JSON.parse(this.app.secretStorage.getSecret(`ptv2-raeume-${this.vaultKennung}`) ?? '{}');
    }
    return z;
  }

  zustandSpeichern(): void {
    const { verbindung, raeume, ...rest } = this.z;
    const ohne = verbindung ? { ...verbindung, token: '', schluessel: '' } : null;
    this.app.saveLocalStorage('ptv2-sync-zustand', JSON.stringify({ ...rest, raeume: {}, verbindung: ohne }));
    if (verbindung) {
      this.app.secretStorage.setSecret(`ptv2-token-${this.vaultKennung}`, verbindung.token);
      this.app.secretStorage.setSecret(`ptv2-schluessel-${this.vaultKennung}`, verbindung.schluessel);
      this.app.secretStorage.setSecret(`ptv2-raeume-${this.vaultKennung}`, JSON.stringify(raeume));
    }
  }

  private neuerAbgleich(): VaultAbgleich {
    return new VaultAbgleich(
      new ObsidianFs(this.app),
      this.z,
      (v: Verbindung) => new SyncApi(v.server, obsidianTransport, v.token),
      () => ({ maxBytes: this.einstellungen.maxMiB * 1024 * 1024 }),
    );
  }

  async einstellungenSpeichern(): Promise<void> {
    await this.saveData(this.einstellungen);
  }

  get geraetName(): string {
    return (this.app.loadLocalStorage('ptv2-sync-geraetname') as string | null) ?? (navigator.userAgent.includes('Android') ? 'Obsidian Android' : 'Obsidian');
  }

  set geraetName(n: string) {
    this.app.saveLocalStorage('ptv2-sync-geraetname', n);
  }

  // ---------------------------------------------------------------
  // Abgleich

  private bald(): void {
    if (!this.z.eingerichtet || !this.einstellungen.automatisch) return;
    if (this.zeitgeber !== null) window.clearTimeout(this.zeitgeber);
    this.zeitgeber = window.setTimeout(() => {
      this.zeitgeber = null;
      void this.abgleichen(false);
    }, 5000);
  }

  async abgleichen(manuell: boolean): Promise<void> {
    if (!this.z.verbindung || !this.z.eingerichtet) {
      if (manuell) new Notice('Personal Tracker Sync ist noch nicht eingerichtet (Einstellungen → Personal Tracker Sync).');
      return;
    }
    if (!manuell && !this.einstellungen.automatisch) return;
    if (this.laufend) {
      this.nochmal = true;
      return this.laufend;
    }
    this.laufend = this.lauf(manuell).finally(() => {
      this.laufend = null;
      if (this.nochmal) {
        this.nochmal = false;
        void this.abgleichen(false);
      }
    });
    return this.laufend;
  }

  private async lauf(manuell: boolean): Promise<void> {
    this.status = 'läuft …';
    this.statusZeigen();
    try {
      this.letzter = await this.abgleich.abgleichen();
      this.fehler = undefined;
      const b = this.letzter;
      if (b.nurLesen.length > 0) {
        new Notice(`Personal Tracker Sync: Änderungen in einem nur lesbaren geteilten Ordner wurden nicht hochgeladen, sondern nach „${b.nurLesen[0]}“ verschoben.`, 12000);
      }
      if (b.raeumeEntfernt.length > 0) new Notice(`Personal Tracker Sync: Kein Zugang mehr zu „${b.raeumeEntfernt.join('“, „')}“.`, 10000);
      if (b.konflikte.length > 0) new Notice(`Personal Tracker Sync: ${b.konflikte.length} Konfliktkopie(n) angelegt, z. B. „${b.konflikte[0]}“.`, 10000);
      if (manuell) new Notice(`Abgeglichen: ${b.geholt} geholt, ${b.gesendet} gesendet.`);
    } catch (e) {
      this.fehler = e instanceof SyncFehler ? e.message : `Abgleich fehlgeschlagen: ${e}`;
      if (manuell) new Notice(this.fehler, 8000);
    } finally {
      this.zustandSpeichern();
      this.status = '';
      this.statusZeigen();
    }
  }

  statusZeigen(): void {
    let t: string;
    if (!this.z.verbindung) t = 'Sync: nicht verbunden';
    else if (!this.z.eingerichtet) t = 'Sync: Einrichtung offen';
    else if (this.status) t = `Sync: ${this.status}`;
    else if (this.fehler) t = 'Sync: Fehler';
    else {
      const gesperrt = this.letzter?.gesperrt.size ?? 0;
      const offen = this.abgleich.ausstehend;
      t = gesperrt > 0 ? `Sync: ${gesperrt} gesperrt` : offen > 0 ? `Sync: ${offen} ausstehend` : 'Sync: aktuell';
    }
    this.statusLeiste.setText(t);
    this.statusLeiste.setAttr('aria-label', this.fehler ?? 'Personal Tracker Sync');
  }

  // ---------------------------------------------------------------
  // Verbinden, Einrichten, Trennen

  async verbinden(server: string, code: string, name: string): Promise<void> {
    this.z.verbindung = await koppeln(server, code, name, obsidianTransport);
    this.z.eingerichtet = false;
    this.einstellungen.server = this.z.verbindung.server;
    this.geraetName = name;
    await this.einstellungenSpeichern();
    this.zustandSpeichern();
    this.statusZeigen();
  }

  async vorschauOeffnen(): Promise<void> {
    if (!this.z.verbindung) {
      new Notice('Erst in den Einstellungen mit einem Kopplungscode verbinden.');
      return;
    }
    const n = new Notice('Vault wird durchgesehen …', 0);
    try {
      const v = await this.abgleich.vorschau();
      this.zustandSpeichern();
      n.hide();
      new VorschauModal(this.app, this, v).open();
    } catch (e) {
      n.hide();
      new Notice(e instanceof Error ? e.message : String(e), 8000);
    }
  }

  async einrichten(): Promise<void> {
    this.z.eingerichtet = true;
    this.zustandSpeichern();
    await this.abgleichen(true);
  }

  /** Andere Programme, die denselben Ordner abgleichen. */
  async andereSchreiber(): Promise<string[]> {
    const a = this.app.vault.adapter;
    const w: string[] = [];
    if (await a.exists('.stfolder')) w.push('Syncthing gleicht diesen Ordner ebenfalls ab.');
    try {
      const kern = JSON.parse(await a.read(normalizePath(`${this.app.vault.configDir}/core-plugins.json`)));
      if ((Array.isArray(kern) && kern.includes('sync')) || kern?.sync === true) w.push('Obsidian Sync ist eingeschaltet.');
    } catch {
      // keine Liste
    }
    if (await a.exists('.git')) w.push('Der Vault ist ein Git-Repository (.git wird nicht übertragen).');
    return w;
  }

  async sicherungErstellen(): Promise<string> {
    const fs = new ObsidianFs(this.app);
    const dateien = [];
    for (const f of await fs.liste()) {
      if (ausnahme(f.pfad)) continue;
      dateien.push({ pfad: f.pfad, daten: await fs.lesen(f.pfad) });
    }
    const jetzt = new Date();
    const zwei = (x: number) => String(x).padStart(2, '0');
    const name = `.ptv2-sicherung/vault-${jetzt.getFullYear()}-${zwei(jetzt.getMonth() + 1)}-${zwei(jetzt.getDate())}-${zwei(jetzt.getHours())}${zwei(jetzt.getMinutes())}.zip`;
    if (!(await this.app.vault.adapter.exists('.ptv2-sicherung'))) await this.app.vault.adapter.mkdir('.ptv2-sicherung');
    const z = zip(dateien, jetzt);
    await this.app.vault.adapter.writeBinary(name, z.buffer.slice(z.byteOffset, z.byteOffset + z.byteLength));
    return name;
  }

  async trennen(): Promise<void> {
    const v = this.z.verbindung;
    if (v) {
      try {
        await new SyncApi(v.server, obsidianTransport, v.token).geraetEntfernen(v.geraet);
      } catch {
        // offline oder schon entfernt: lokal trotzdem trennen
      }
    }
    Object.assign(this.z, leererZustand());
    this.app.secretStorage.setSecret(`ptv2-token-${this.vaultKennung}`, '');
    this.app.secretStorage.setSecret(`ptv2-schluessel-${this.vaultKennung}`, '');
    this.app.secretStorage.setSecret(`ptv2-raeume-${this.vaultKennung}`, '');
    this.zustandSpeichern();
    this.letzter = undefined;
    this.fehler = undefined;
    this.statusZeigen();
  }
}

function trefferText(t: SecretTreffer[]): string {
  return t.map((x) => `${x.regel} (Zeile ${x.zeile})`).join(', ');
}

function liste(el: HTMLElement, titel: string, eintraege: string[], offen = false): void {
  if (eintraege.length === 0) return;
  const d = el.createEl('details');
  if (offen) d.setAttr('open', '');
  d.createEl('summary', { text: `${titel}: ${eintraege.length}` });
  const ul = d.createEl('ul', { cls: 'ptv2-liste' });
  for (const e of eintraege.slice(0, 2000)) ul.createEl('li', { text: e });
  if (eintraege.length > 2000) ul.createEl('li', { text: `… und ${eintraege.length - 2000} weitere` });
}

class VorschauModal extends Modal {
  private readonly plugin: PersonalTrackerSync;
  private readonly v: Vorschau;

  constructor(app: App, plugin: PersonalTrackerSync, v: Vorschau) {
    super(app);
    this.plugin = plugin;
    this.v = v;
  }

  async onOpen(): Promise<void> {
    const { contentEl: el, v } = this;
    el.addClass('ptv2-vorschau');
    this.setTitle('Vault-Sync einrichten');
    el.createEl('p', {
      text:
        'So würde der erste Abgleich aussehen. Noch ist nichts übertragen. Alles wird auf diesem Gerät verschlüsselt; der Server sieht keine Inhalte und keine Dateinamen.',
    });
    for (const w of await this.plugin.andereSchreiber()) {
      el.createEl('p', { cls: 'ptv2-warnung', text: `Achtung: ${w} Zwei Programme, die dieselben Dateien abgleichen, können sich gegenseitig Änderungen überschreiben oder Dubletten erzeugen. Für den Anfang einen eigenen Test-Vault verwenden.` });
    }
    const mib = (n: number) => `${(n / 1024 / 1024).toFixed(1)} MiB`;
    liste(el, `Hochladen (${mib(v.bytesHoch)})`, v.hochladen);
    liste(el, 'Vom Server holen', v.herunterladen);
    liste(el, 'In geteilten Ordnern (gehen an die jeweilige Freigabe)', v.geteilt);
    liste(el, 'Auf beiden Seiten gleich', v.gleich);
    liste(el, 'Gleicher Pfad, anderer Inhalt (deine Fassung bleibt als Konfliktkopie)', v.konflikte, true);
    liste(el, 'Gesperrt wegen möglicher Secrets (bleiben lokal, bis du sie einzeln freigibst)', v.gesperrt.map((g) => `${g.pfad} – ${trefferText(g.treffer)}`), true);
    liste(el, `Größer als ${this.plugin.einstellungen.maxMiB} MiB (bleiben lokal)`, v.zuGross, true);
    liste(el, 'Nicht übertragen', v.ausgenommen.map((a) => `${a.pfad} – ${a.grund}`));
    if (v.nichtGeprueft > 0) {
      el.createEl('p', { text: `${v.nichtGeprueft === 1 ? '1 Datei ist' : `${v.nichtGeprueft} Dateien sind`} binär oder sehr groß und wurde${v.nichtGeprueft === 1 ? '' : 'n'} nicht auf Secrets geprüft. Die Erkennung arbeitet mit Mustern und kann Secrets übersehen, auch in Plugin-Einstellungen. Bitte selbst durchsehen, was in .obsidian/plugins liegt.` });
    }

    let geprueft = false;
    new Setting(el)
      .setName('Sicherung')
      .setDesc('ZIP des ganzen Vaults (ohne Ausnahmen) in .ptv2-sicherung/. Bitte danach an einen zweiten Ort kopieren.')
      .addButton((b) =>
        b.setButtonText('Sicherung erstellen').onClick(async () => {
          b.setDisabled(true);
          try {
            new Notice(`Sicherung gespeichert: ${await this.plugin.sicherungErstellen()}`, 10000);
          } finally {
            b.setDisabled(false);
          }
        }),
      );
    new Setting(el).setName('Ich habe die Liste geprüft').addToggle((t) => t.onChange((x) => (geprueft = x)));
    new Setting(el).addButton((b) =>
      b
        .setButtonText('Einrichten und abgleichen')
        .setCta()
        .onClick(async () => {
          if (!geprueft) {
            new Notice('Bitte zuerst bestätigen, dass du die Liste geprüft hast.');
            return;
          }
          this.close();
          await this.plugin.einrichten();
        }),
    );
  }

  onClose(): void {
    this.contentEl.empty();
  }
}

class EinstellungenSeite extends PluginSettingTab {
  private readonly plugin: PersonalTrackerSync;

  constructor(app: App, plugin: PersonalTrackerSync) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display(): void {
    const { containerEl: el, plugin } = this;
    el.empty();
    el.createEl('p', {
      text: 'Gleicht den ganzen Vault Ende-zu-Ende-verschlüsselt mit deinem Personal-Tracker-Server ab. Die Tracker-App zeigt die Dateien dann auch an.',
    });

    if (!plugin.z.verbindung) {
      let server = plugin.einstellungen.server;
      let code = '';
      let name = plugin.geraetName;
      new Setting(el).setName('Serveradresse').setDesc('z. B. https://sync.example.org').addText((t) => t.setValue(server).onChange((x) => (server = x)));
      new Setting(el).setName('Gerätename').addText((t) => t.setValue(name).onChange((x) => (name = x)));
      new Setting(el)
        .setName('Kopplungscode')
        .setDesc('In der Tracker-App: Speicher & Sicherheit → Sync → Gerät hinzufügen. 10 Minuten gültig.')
        .addText((t) => t.setPlaceholder('XXXX-XXXX-XXXX-XXXX-XXXX').onChange((x) => (code = x)));
      new Setting(el).addButton((b) =>
        b
          .setButtonText('Verbinden')
          .setCta()
          .onClick(async () => {
            b.setDisabled(true);
            try {
              await plugin.verbinden(server, code, name.trim() || 'Obsidian');
              new Notice('Verbunden. Als Nächstes die Vorschau prüfen.');
              this.display();
              await plugin.vorschauOeffnen();
            } catch (e) {
              new Notice(e instanceof Error ? e.message : String(e), 8000);
            } finally {
              b.setDisabled(false);
            }
          }),
      );
      return;
    }

    const v = plugin.z.verbindung;
    new Setting(el).setName('Verbunden mit').setDesc(`${v.server} als „${v.name}“`);
    if (!plugin.z.eingerichtet) {
      new Setting(el)
        .setName('Einrichtung')
        .setDesc('Vor dem ersten Abgleich alle Pfade, Secret-Treffer und Ausnahmen ansehen.')
        .addButton((b) => b.setButtonText('Vorschau und Einrichtung').setCta().onClick(() => void plugin.vorschauOeffnen()));
    } else {
      const s = plugin.letzter;
      new Setting(el)
        .setName('Status')
        .setDesc(plugin.fehler ?? (s ? `Zuletzt: ${s.geholt} geholt, ${s.gesendet} gesendet. Ausstehend: ${plugin.abgleich.ausstehend}.` : 'Noch kein Abgleich in dieser Sitzung.'))
        .addButton((b) =>
          b.setButtonText('Jetzt abgleichen').onClick(async () => {
            await plugin.abgleichen(true);
            this.display();
          }),
        );
      new Setting(el)
        .setName('Automatisch abgleichen')
        .setDesc('Beim Start, kurz nach Änderungen und alle 5 Minuten, solange Obsidian offen ist.')
        .addToggle((t) =>
          t.setValue(plugin.einstellungen.automatisch).onChange(async (x) => {
            plugin.einstellungen.automatisch = x;
            await plugin.einstellungenSpeichern();
          }),
        );
      if (s && s.gesperrt.size > 0) {
        el.createEl('h3', { text: 'Wegen möglicher Secrets gesperrt' });
        el.createEl('p', { text: 'Diese Dateien bleiben auf diesem Gerät. Eine Freigabe gilt nur für den jetzigen Inhalt; nach jeder Änderung wird neu geprüft.' });
        for (const [id, t] of s.gesperrt) {
          const pfad = plugin.abgleich.pfadVon(id) ?? id;
          new Setting(el)
            .setName(pfad)
            .setDesc(trefferText(t))
            .addButton((b) =>
              b.setButtonText('Diese Fassung freigeben').setWarning().onClick(async () => {
                plugin.abgleich.freigeben(pfad);
                plugin.zustandSpeichern();
                await plugin.abgleichen(true);
                this.display();
              }),
            );
        }
      }
      const raeume = plugin.abgleich.raeume;
      if (raeume.length > 0) {
        el.createEl('h3', { text: 'Geteilte Ordner' });
        el.createEl('p', { text: 'Verwaltet werden Freigaben in der Tracker-App (Freigaben). Alles unter diesen Ordnern gehört zur jeweiligen Freigabe.' });
        for (const r of raeume) {
          const recht = r.eigen ? 'von dir geteilt' : r.schreibbar ? `von ${r.j.von ?? '?'}, lesen und schreiben` : `von ${r.j.von ?? '?'}, nur lesen`;
          new Setting(el).setName(r.ordner ?? r.j.name).setDesc(`„${r.j.name}“ – ${recht}`);
        }
      }
      if (s && s.zuGross.length > 0) {
        el.createEl('h3', { text: 'Zu groß (bleiben lokal)' });
        el.createEl('p', { text: s.zuGross.join(', ') });
      }
    }

    new Setting(el)
      .setName('Größte Datei (MiB)')
      .setDesc('Größere Dateien werden nicht übertragen.')
      .addText((t) =>
        t.setValue(String(plugin.einstellungen.maxMiB)).onChange(async (x) => {
          const n = Number.parseInt(x, 10);
          if (Number.isFinite(n) && n > 0) {
            plugin.einstellungen.maxMiB = n;
            await plugin.einstellungenSpeichern();
          }
        }),
      );
    new Setting(el)
      .setName('Sicherung')
      .setDesc('ZIP des Vaults in .ptv2-sicherung/.')
      .addButton((b) => b.setButtonText('Sicherung erstellen').onClick(async () => new Notice(`Gespeichert: ${await plugin.sicherungErstellen()}`, 10000)));
    new Setting(el)
      .setName('Trennen')
      .setDesc('Dieses Gerät beim Server abmelden. Die Dateien bleiben hier unverändert.')
      .addButton((b) =>
        b
          .setButtonText('Trennen')
          .setWarning()
          .onClick(async () => {
            await plugin.trennen();
            this.display();
          }),
      );
  }
}
