// Secret-Erkennung vor dem Hochladen; dieselben Muster wie in der App
// (protokoll/secret-muster.json). Treffer nennen nur Regel und Zeile.

import muster from '../../protokoll/secret-muster.json' with { type: 'json' };

export interface SecretTreffer {
  regel: string;
  zeile: number;
}

interface Regel {
  name: string;
  muster: RegExp;
  wert?: number;
}

const regeln: Regel[] = muster.regeln.map((r: { name: string; muster: string; flags?: string; wert?: number }) => ({
  name: r.name,
  muster: new RegExp(r.muster, 'g' + (r.flags ?? '')),
  wert: r.wert,
}));
const platzhalter = new RegExp(muster.platzhalter, 'i');

export const MAX_PRUEFGROESSE = 10 * 1024 * 1024;

export function istText(b: Uint8Array): boolean {
  const n = Math.min(b.length, 8192);
  for (let i = 0; i < n; i++) if (b[i] === 0) return false;
  return true;
}

export function pruefeText(text: string): SecretTreffer[] {
  const treffer: SecretTreffer[] = [];
  const zeilen = text.split('\n');
  zeilen.forEach((zeile, z) => {
    for (const r of regeln) {
      r.muster.lastIndex = 0;
      for (const m of zeile.matchAll(r.muster)) {
        const w = r.wert === undefined ? undefined : m[r.wert];
        if (w !== undefined && platzhalter.test(w.replace(/[,;.)\]]+$/, ''))) continue;
        treffer.push({ regel: r.name, zeile: z + 1 });
        break;
      }
    }
  });
  return treffer;
}

/** `null`: nicht prüfbar (binär oder zu groß). */
export function pruefen(inhalt: Uint8Array): SecretTreffer[] | null {
  if (inhalt.length > MAX_PRUEFGROESSE || !istText(inhalt)) return null;
  return pruefeText(new TextDecoder().decode(inhalt));
}
