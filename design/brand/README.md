# PORTSIDE / SAIL IDENTITY — v1.0

**Direction:** Nautical sail silhouette with a quiet, geometric P suggestion. Navy, sailcloth, and safety-orange primary palette.

## Start here
- `brand-guide/portside-brand-identity-v1.pdf` — 9-page identity presentation.
- `brand-guide/portside-brand-overview.png` — visual overview.
- `master-svg/portside-sail-mark-editable-master.svg` — fully editable paths, no raster artwork.
- `icon-composer/AppIcon.icon/` — Icon Composer format package (`icon.json` and layered SVG assets). See adjacent README.
- `macos-icns/portside-dark.icns` — native .icns fallback.

## Files
- `master-svg/` — transparent symbol, geometry source, and square icons.
- `png-exports/` — 16 to 1024px icons (4 colorways), transparent marks.
- `wordmarks/` — horizontal/stacked SVG, both editable live text and paths converted to outlines; previews.
- `menubar/` — black, white, and navy SVG + PNG assets at status-bar sizes.
- `icon-composer/` — layered AppIcon.icon and individual import sources.
- `macos-icns/` — .icns legacy macOS icon exports.
- `brand-guide/` — 9-page PDF with source SVG pages and PNG previews.
- `mockups/` — macOS Dock and settings illustrations, both SVG and PNG.
- `design-tokens/` — color JSON and CSS variables.

## Typography
Display: Inter Display Semibold, a freely accessible font. Product interface: prefer the system's SF Pro. Font files are deliberately not included. Wordmark SVGs labeled `outlined` are paths and display consistently without any font installed.

## App icon use
The 1024px PNGs are flat transparent-corner app-icon assets (do not upscale small icons). Prefer Icon Composer when targeting newer macOS, or the packaged `.icns` as a traditional fallback. The Icon Composer `.icon` is a real directory-form package, but **not tested in Apple's editor** in this environment; see verification instructions.

## Keep it simple
Never add waves, ropes, literal letters, shine effects, translucent glass atop the mark, or extra accent colors. The sail geometry is the identity.
