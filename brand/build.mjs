// Renders every Homecast icon raster from `params.json`.
//
// The mark used to exist as six independently-generated PNG copies with one
// stray vector source, and the palette had already drifted apart between them
// (#3478F6 on the Android path vs #3B82F6 everywhere else). Everything now
// comes from here, so the next change to the logo is a change to one file.
//
// Output is committed. This is NOT part of any app build — nothing in CI needs
// sharp. Run it only when the mark or the palette changes:
//
//   cd brand && npm install && npm run build
//
// Deliberately does NOT use `npx tauri icon`: that rewrites the adaptive-icon
// XML and drawables under gen/android, which are hand-edited and committed.
// This script only ever touches the files it names below.

import sharp from 'sharp';
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, '..');                 // homecast/
const SIBLING = join(REPO, '..');              // ~/Documents/GitHub/
const P = JSON.parse(readFileSync(join(HERE, 'params.json'), 'utf8'));

const GRAD_FROM = '#3B82F6';
const GRAD_TO = '#2563EB';
const TILE_RX = 238;                           // 23% — measured off the source artwork
const VB = 1024;

const D = (v) => Math.round(v * 100) / 100;
let wrote = 0;

/* ── geometry ─────────────────────────────────────────────────────────────── */

/** Rounded corner between P→V→Q. Sweep comes from the arc centre, not a cross
 *  product — the cross product gets it backwards at the apex and leaves a notch. */
function corner(Pt, V, Q, r) {
  const u = [Pt[0] - V[0], Pt[1] - V[1]];
  const w = [Q[0] - V[0], Q[1] - V[1]];
  const lu = Math.hypot(...u), lw = Math.hypot(...w);
  const un = [u[0] / lu, u[1] / lu], wn = [w[0] / lw, w[1] / lw];
  const ang = Math.acos(Math.max(-1, Math.min(1, un[0] * wn[0] + un[1] * wn[1])));
  const t = r / Math.tan(ang / 2);
  const t1 = [V[0] + un[0] * t, V[1] + un[1] * t];
  const t2 = [V[0] + wn[0] * t, V[1] + wn[1] * t];
  let bx = un[0] + wn[0], by = un[1] + wn[1];
  const bl = Math.hypot(bx, by) || 1;
  bx /= bl; by /= bl;
  const C = [V[0] + bx * (r / Math.sin(ang / 2)), V[1] + by * (r / Math.sin(ang / 2))];
  let delta = Math.atan2(t2[1] - C[1], t2[0] - C[0]) - Math.atan2(t1[1] - C[1], t1[0] - C[0]);
  while (delta > Math.PI) delta -= 2 * Math.PI;
  while (delta < -Math.PI) delta += 2 * Math.PI;
  return { t1, t2, sweep: delta > 0 ? 1 : 0 };
}

/** The house: a closed rounded pentagon (apex, both eaves, both floor corners). */
function housePath() {
  const V = [
    { p: [P.AX, P.AY], r: P.AR },
    { p: [P.RX, P.RJY], r: P.JR },
    { p: [P.RX, P.FY], r: P.CR },
    { p: [P.LX, P.FY], r: P.CR },
    { p: [P.LX, P.LJ], r: P.JR },
  ];
  const n = V.length;
  const C = V.map((v, i) => corner(V[(i - 1 + n) % n].p, v.p, V[(i + 1) % n].p, v.r));
  let d = `M${D(C[0].t2[0])} ${D(C[0].t2[1])}`;
  for (let i = 1; i < n; i++) {
    d += ` L${D(C[i].t1[0])} ${D(C[i].t1[1])}`
      + ` A${D(V[i].r)} ${D(V[i].r)} 0 0 ${C[i].sweep} ${D(C[i].t2[0])} ${D(C[i].t2[1])}`;
  }
  d += ` L${D(C[0].t1[0])} ${D(C[0].t1[1])}`
    + ` A${D(V[0].r)} ${D(V[0].r)} 0 0 ${C[0].sweep} ${D(C[0].t2[0])} ${D(C[0].t2[1])} Z`;
  return d;
}

const arcPath = (cx, cy, r, a0, a1) => {
  const A = (a0 * Math.PI) / 180, B = (a1 * Math.PI) / 180;
  return `M${D(cx + r * Math.cos(A))} ${D(cy + r * Math.sin(A))}`
    + ` A${D(r)} ${D(r)} 0 0 1 ${D(cx + r * Math.cos(B))} ${D(cy + r * Math.sin(B))}`;
};

const HOUSE = housePath();
// Both waves, at every size. A one-wave variant for tiny icons was built and
// rejected: a mark that drops a wave is a different mark, and having two of them
// in circulation is how logos drift apart in the first place.
const WAVES = [
  arcPath(P.C1X, P.C1Y, P.R1, P.S1, P.E1),
  arcPath(P.C2X, P.C2Y, P.R2, P.S2, P.E2),
];

const glyph = (color) => `<g fill="none" stroke="${color}" stroke-width="${P.SW}"`
  + ` stroke-linecap="round" stroke-linejoin="round">\n`
  + `    <path d="${HOUSE}"/>\n`
  + WAVES.map((w) => `    <path d="${w}"/>`).join('\n')
  + `\n  </g>\n  <circle cx="${P.DX}" cy="${P.DY}" r="${P.DR}" fill="${color}"/>`;

/* ── documents ────────────────────────────────────────────────────────────── */

/** The tile. `rx: 0` gives the full-bleed square iOS and maskable icons need. */
const iconSvg = ({ rx = TILE_RX } = {}) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${VB}" height="${VB}" viewBox="0 0 ${VB} ${VB}" role="img" aria-label="Homecast">
  <defs>
    <linearGradient id="hc" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="${GRAD_FROM}"/>
      <stop offset="1" stop-color="${GRAD_TO}"/>
    </linearGradient>
  </defs>
  <rect width="${VB}" height="${VB}"${rx ? ` rx="${rx}"` : ''} fill="url(#hc)"/>
  ${glyph('#fff')}
</svg>
`;

/** Glyph alone. `viewBox` is tightened by callers so small icons fill their box. */
const markSvg = ({ color = 'currentColor', viewBox = `0 0 ${VB} ${VB}` } = {}) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${VB}" height="${VB}" viewBox="${viewBox}" role="img" aria-label="Homecast">
  ${glyph(color)}
</svg>
`;

/* ── raster helpers ───────────────────────────────────────────────────────── */

const png = (svg, size) =>
  sharp(Buffer.from(svg), { density: 384 }).resize(size, size, { fit: 'fill' }).png().toBuffer();

async function out(path, buf) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, buf);
  wrote++;
  console.log('  ' + path.replace(SIBLING + '/', ''));
}

/** Favicon frames only.
 *
 *  In the full tile the glyph is 62% of the width, which is right at 192px and
 *  illegible at 16 — the mark washes out into a blue square. Tiny frames get the
 *  glyph enlarged to 82% and the corner radius pulled in, so no pixels are spent
 *  on corners that a 16px favicon cannot show anyway. */
async function compactIconPng(size) {
  const inner = Math.round(size * 0.82);
  const rx = Math.round(size * 0.18);
  const tile = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
      <defs><linearGradient id="hc" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="${GRAD_FROM}"/><stop offset="1" stop-color="${GRAD_TO}"/>
      </linearGradient></defs>
      <rect width="${size}" height="${size}" rx="${rx}" fill="url(#hc)"/>
    </svg>`);
  const off = Math.round((size - inner) / 2);
  return sharp(tile, { density: 384 }).resize(size, size, { fit: 'fill' })
    .composite([{
      input: await png(markSvg({ color: '#fff', viewBox: TIGHT }), inner),
      top: off, left: off,
    }]).png().toBuffer();
}

/** Ink bounding box of the glyph, so tight-cropped variants are measured, not guessed. */
async function inkBox() {
  const buf = await sharp(Buffer.from(markSvg({ color: '#fff' })), { density: 384 })
    .resize(VB, VB, { fit: 'fill' }).flatten({ background: '#000' }).greyscale().raw().toBuffer();
  let T = VB, B = -1, L = VB, R = -1;
  for (let y = 0; y < VB; y++) {
    for (let x = 0; x < VB; x++) {
      if (buf[y * VB + x] > 110) {
        if (y < T) T = y; if (y > B) B = y; if (x < L) L = x; if (x > R) R = x;
      }
    }
  }
  return { T, B, L, R };
}

/* ── main ─────────────────────────────────────────────────────────────────── */

const box = await inkBox();
// square, centred on the ink, with a little air — used for every glyph-only target
const pad = 26;
const cx = (box.L + box.R) / 2, cy = (box.T + box.B) / 2;
const side = Math.max(box.R - box.L, box.B - box.T) + pad * 2;
const TIGHT = `${D(cx - side / 2)} ${D(cy - side / 2)} ${D(side)} ${D(side)}`;

const ICON = iconSvg();
const ICON_SQUARE = iconSvg({ rx: 0 });

console.log(`ink ${box.L},${box.T} → ${box.R},${box.B}   tight viewBox "${TIGHT}"\n`);

/* 2. Mac + iOS ------------------------------------------------------------- */
console.log('\napp-ios-macos/');
const XC = join(REPO, 'app-ios-macos/Resources/Assets.xcassets');

// iOS marketing icon: full-bleed square, no transparency — the system masks it.
await out(join(XC, 'AppIcon.appiconset/AppIcon.png'),
  await sharp(await png(ICON_SQUARE, 1024)).flatten({ background: GRAD_FROM }).png().toBuffer());

// macOS icon grid: rounded art inset to 824/1024 on a transparent canvas.
const macIcon = async (size) => {
  const art = Math.round((size * 824) / 1024);
  const pad2 = Math.round((size - art) / 2);
  return sharp({ create: { width: size, height: size, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
    .composite([{ input: await png(ICON, art), top: pad2, left: pad2 }]).png().toBuffer();
};
await out(join(XC, 'AppIcon.appiconset/AppIcon-mac.png'), await macIcon(512));
await out(join(XC, 'AppIcon.appiconset/AppIcon-mac-2x.png'), await macIcon(1024));

for (const s of [128, 256, 512]) {
  await out(join(XC, `LaunchIcon.imageset/icon-${s}.png`), await png(ICON, s));
}
// Template images: solid black on transparent, tinted by AppKit at draw time.
const tmpl = (size) => png(markSvg({ color: '#000', viewBox: TIGHT }), size);
await out(join(XC, 'MenuBarIcon.imageset/menubar-icon.png'), await tmpl(18));
await out(join(XC, 'MenuBarIcon.imageset/menubar-icon@2x.png'), await tmpl(36));
await out(join(XC, 'MenuBarIcon.imageset/menubar-icon@3x.png'), await tmpl(54));
await out(join(XC, 'MenuBarIconOutline.imageset/menubar-icon-outline.png'), await tmpl(25));
await out(join(XC, 'MenuBarIconOutline.imageset/menubar-icon-outline@2x.png'), await tmpl(50));
await out(join(XC, 'MenuBarIconOutline.imageset/menubar-icon-outline@3x.png'), await tmpl(75));

/* 3. Tauri desktop + Android ---------------------------------------------- */
console.log('\napp-android-windows-linux/');
const TAURI = join(REPO, 'app-android-windows-linux/src-tauri');

for (const [name, size] of [['32x32.png', 32], ['128x128.png', 128], ['128x128@2x.png', 256], ['icon.png', 512]]) {
  await out(join(TAURI, 'icons', name), await png(ICON, size));
}

// .icns via iconutil (macOS), .ico via ImageMagick — both need a temp iconset.
const ICONSET = join(TAURI, 'icons/homecast.iconset');
rmSync(ICONSET, { recursive: true, force: true });
mkdirSync(ICONSET, { recursive: true });
for (const [nm, sz] of [['16x16', 16], ['16x16@2x', 32], ['32x32', 32], ['32x32@2x', 64],
  ['128x128', 128], ['128x128@2x', 256], ['256x256', 256], ['256x256@2x', 512],
  ['512x512', 512], ['512x512@2x', 1024]]) {
  writeFileSync(join(ICONSET, `icon_${nm}.png`), await png(ICON, sz));
}
execFileSync('iconutil', ['-c', 'icns', ICONSET, '-o', join(TAURI, 'icons/icon.icns')]);
rmSync(ICONSET, { recursive: true, force: true });
console.log('  ' + join(TAURI, 'icons/icon.icns').replace(SIBLING + '/', ''));
wrote++;

const icoTmp = join(HERE, '.ico-tmp');
mkdirSync(icoTmp, { recursive: true });
const icoParts = [];
for (const s of [16, 32, 48, 64, 128, 256]) {
  const f = join(icoTmp, `${s}.png`);
  writeFileSync(f, await png(ICON, s));
  icoParts.push(f);
}
execFileSync('magick', [...icoParts, join(TAURI, 'icons/icon.ico')]);
rmSync(icoTmp, { recursive: true, force: true });
console.log('  ' + join(TAURI, 'icons/icon.ico').replace(SIBLING + '/', ''));
wrote++;

const RES = join(TAURI, 'gen/android/app/src/main/res');
const DPI = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
for (const [dpi, k] of Object.entries(DPI)) {
  const s = Math.round(48 * k);
  await out(join(RES, `mipmap-${dpi}/ic_launcher.png`), await png(ICON, s));
  await out(join(RES, `mipmap-${dpi}/ic_launcher_round.png`),
    await sharp(await png(ICON_SQUARE, s))
      .composite([{
        input: Buffer.from(`<svg width="${s}" height="${s}"><circle cx="${s / 2}" cy="${s / 2}" r="${s / 2}" fill="#fff"/></svg>`),
        blend: 'dest-in',
      }]).png().toBuffer());

  // Adaptive foreground: glyph inside the 72/108 safe zone, rest transparent.
  const fg = Math.round(108 * k);
  const inner = Math.round(fg * (72 / 108));
  await out(join(RES, `mipmap-${dpi}/ic_launcher_foreground.png`),
    await sharp({ create: { width: fg, height: fg, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
      .composite([{
        input: await png(markSvg({ color: '#fff', viewBox: TIGHT }), inner),
        top: Math.round((fg - inner) / 2), left: Math.round((fg - inner) / 2),
      }]).png().toBuffer());

  // Status-bar icon: white on transparent; Android flattens alpha and tints it.
  const stat = Math.round(24 * k);
  await out(join(RES, `drawable-${dpi}/ic_stat_homecast.png`),
    await png(markSvg({ color: '#fff', viewBox: TIGHT }), stat));
}

// Tauri's iOS project (unused by our pipeline, but kept consistent so it can't drift).
const TIOS = join(TAURI, 'gen/apple/Assets.xcassets/AppIcon.appiconset');
for (const [name, size] of [
  ['AppIcon-20x20@1x', 20], ['AppIcon-20x20@2x', 40], ['AppIcon-20x20@2x-1', 40], ['AppIcon-20x20@3x', 60],
  ['AppIcon-29x29@1x', 29], ['AppIcon-29x29@2x', 58], ['AppIcon-29x29@2x-1', 58], ['AppIcon-29x29@3x', 87],
  ['AppIcon-40x40@1x', 40], ['AppIcon-40x40@2x', 80], ['AppIcon-40x40@2x-1', 80], ['AppIcon-40x40@3x', 120],
  ['AppIcon-60x60@2x', 120], ['AppIcon-60x60@3x', 180],
  ['AppIcon-76x76@1x', 76], ['AppIcon-76x76@2x', 152],
  ['AppIcon-83.5x83.5@2x', 167], ['AppIcon-512@2x', 1024],
]) {
  await out(join(TIOS, `${name}.png`),
    await sharp(await png(ICON_SQUARE, size)).flatten({ background: GRAD_FROM }).png().toBuffer());
}

// Play Store listing assets. These used to be read from /tmp/play-assets, which
// does not exist — the store icon was unreproducible from source.
const PLAY = join(REPO, 'app-android-windows-linux/scripts/play/assets');
await out(join(PLAY, 'icon-512.png'),
  await sharp(await png(ICON_SQUARE, 512)).flatten({ background: GRAD_FROM }).png().toBuffer());
await out(join(PLAY, 'feature-1024x500.png'),
  await sharp({
    create: {
      width: 1024, height: 500, channels: 4,
      background: { r: 0x1e, g: 0x5f, b: 0xd8, alpha: 1 },
    },
  }).composite([
    { input: Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="500"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${GRAD_FROM}"/><stop offset="1" stop-color="${GRAD_TO}"/></linearGradient></defs><rect width="1024" height="500" fill="url(#g)"/></svg>`), top: 0, left: 0 },
    { input: await png(markSvg({ color: '#fff', viewBox: TIGHT }), 300), top: 100, left: 362 },
  ]).png().toBuffer());

/* 4. Web ------------------------------------------------------------------- */
console.log('\napp-web/');
const PUB = join(REPO, 'app-web/public');
await out(join(PUB, 'icon-192.png'), await png(ICON, 192));
await out(join(PUB, 'apple-touch-icon.png'),
  await sharp(await png(ICON_SQUARE, 180)).flatten({ background: GRAD_FROM }).png().toBuffer());
await out(join(PUB, 'icon-512.png'),
  await sharp(await png(ICON_SQUARE, 512)).flatten({ background: GRAD_FROM }).png().toBuffer());
await out(join(PUB, 'favicon.svg'), Buffer.from(ICON));
await out(join(PUB, 'og-image.png'),
  await sharp({
    create: { width: 1200, height: 630, channels: 4, background: { r: 0x0b, g: 0x14, b: 0x26, alpha: 1 } },
  }).composite([{ input: await png(ICON, 300), top: 165, left: 450 }]).png().toBuffer());

const favTmp = join(HERE, '.fav-tmp');
mkdirSync(favTmp, { recursive: true });
const favParts = [];
for (const s of [16, 32, 48]) {
  const f = join(favTmp, `${s}.png`);
  writeFileSync(f, await compactIconPng(s));
  favParts.push(f);
}
const FAVICONS = [
  join(PUB, 'favicon.ico'),
  join(SIBLING, 'homecast-cloud/docs/.vitepress/public/favicon.ico'),
  join(SIBLING, 'homecast-cloud/server/homecast/static/favicon.ico'),
];
for (const dest of FAVICONS) {
  if (!existsSync(dirname(dest))) { console.log('  (skip, no dir) ' + dest); continue; }
  execFileSync('magick', [...favParts, dest]);
  console.log('  ' + dest.replace(SIBLING + '/', ''));
  wrote++;
}
rmSync(favTmp, { recursive: true, force: true });

/* 5. homecast-cloud + homecast-hass --------------------------------------- */
console.log('\nsibling repos/');
const cloudLogo = join(SIBLING, 'homecast-cloud/docs/.vitepress/public/logo.svg');
if (existsSync(dirname(cloudLogo))) await out(cloudLogo, Buffer.from(ICON));
const cloudEmail = join(SIBLING, 'homecast-cloud/docs/.vitepress/public/email-logo.png');
if (existsSync(dirname(cloudEmail))) await out(cloudEmail, await png(ICON, 112));

const HASS = join(SIBLING, 'homecast-hass/custom_components/homecast/brand');
if (existsSync(dirname(HASS))) {
  await out(join(HASS, 'icon.png'), await png(ICON, 256));
  await out(join(HASS, 'icon@2x.png'), await png(ICON, 512));
}

console.log(`\n${wrote} files written.`);
