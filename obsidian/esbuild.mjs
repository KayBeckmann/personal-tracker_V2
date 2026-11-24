import { build } from 'esbuild';

await build({
  entryPoints: ['src/main.ts'],
  bundle: true,
  format: 'cjs',
  target: 'es2022',
  platform: 'browser',
  external: ['obsidian', 'electron'],
  outfile: 'main.js',
  logLevel: 'info',
  minify: false,
  sourcemap: false,
  banner: { js: '/* Personal Tracker Sync – Quelltext: obsidian/src im Repository personal-tracker_V2 (MIT). */' },
});
