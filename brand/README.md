# Homecast brand assets

One vector master, every raster derived from it.

```bash
cd brand
npm install
npm run build
```

Output is committed. Nothing in CI or any app build runs this — only run it when the
mark or the palette changes.

## Files

| File | What it is |
|------|------------|
| `icon.svg` | The master: 1024 gradient tile + white mark |
| `mark.svg` | Glyph alone, `currentColor`, transparent background |
| `params.json` | Every number in the drawing |
| `build.mjs` | Generates all 70 rasters across five repos |

`build.mjs` rebuilds the geometry from `params.json` rather than parsing `icon.svg`, so
**`params.json` is the source of truth**. Changing the mark means changing a number there
and re-running the build; the SVGs are outputs that happen to also be committed.

## The mark

1024×1024 viewBox, stroke 61.5, round caps and joins, tile corner radius 238 (23%),
gradient `#3B82F6 → #2563EB` at 135°.

| Element | Geometry |
|---------|----------|
| Apex / eaves / floor corner radii | 82 / 72 / 111 |
| Walls | `x = 219` and `x = 793` |
| Floor | `y = 819.5` |
| Inner wave | centre `(345.5, 708)`, r 131.5, −93.5° → −6° |
| Outer wave | centre `(346, 712.5)`, r 249, −92° → −4° |
| Dot | `(349, 691)`, r 41.5 |

The waves sit 57.3 from the left wall's inner edge and 56.8 from the floor's, measured on
rendered ink rather than path maths so stroke width and round caps are accounted for.

## Things that will bite you

**Both waves, at every size.** A one-wave variant for 16–24px icons was built and rejected.
A mark that drops a wave is a different mark, and two of them in circulation is exactly how
the old icon drifted into six inconsistent copies.

**Do not thicken the stroke at small sizes.** It was tried; it is worse. A heavier stroke
makes the two waves merge into a blob at 18px rather than separating them.

**Do not run `npx tauri icon`.** It rewrites the adaptive-icon XML and the drawables under
`gen/android`, which are hand-edited and committed — the same reason `CLAUDE.md` warns off
`tauri android init`. `build.mjs` only touches files it names explicitly.

**iOS icons must have no alpha.** `AppIcon.png` and the Tauri iOS set are flattened onto the
gradient's start colour and drawn square; the system applies its own mask. macOS is the
opposite — its icons are the rounded tile inset to 824/1024 on a transparent canvas, per
Apple's icon grid.

**Favicon frames below 32px use a compact tile.** At the master's proportions the glyph is
62% of the tile width, which washes out to a flat blue square at 16px. `compactIconPng()`
enlarges the glyph to 82% and pulls the corner radius in for those frames only.

## Where the output lands

| Repo | Targets |
|------|---------|
| `homecast/app-ios-macos` | AppIcon (iOS + macOS), LaunchIcon, both menu-bar template sets |
| `homecast/app-android-windows-linux` | Tauri desktop icons (`.icns`, `.ico`, PNGs), Android launcher + adaptive foreground + status-bar icons, Tauri iOS set, Play Store icon and feature graphic |
| `homecast/app-web` | `icon-192`, `favicon.ico`, `favicon.svg`, `apple-touch-icon`, `icon-512`, `og-image` |
| `homecast-cloud` | docs `logo.svg`, docs + server `favicon.ico`, `email-logo.png` |
| `homecast-hass` | `brand/icon.png`, `brand/icon@2x.png` |

The Android adaptive-icon XML, `site.webmanifest` and `index.html` icon links are wired by
hand, not generated — `build.mjs` produces the images they point at.

Notification icons in `app-web/public/notification-icons/` are a **separate** system with its
own generator (`app-web/scripts/build-notification-icons.mjs`) and its own slug contract. This
build does not touch them.
