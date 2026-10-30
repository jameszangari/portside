# Portside — Approved Sail Artwork — corrected v2

This package corrects the identity mismatch in v1. **The approved original render, not the redesigned v1 vectors, is the source of truth**.

## Choose the right file
- `approved-icon/png/portside-approved-original-1024.png`: faithful 1024px enlargement and extraction from the approved sailboat icon. Shading, shape proportions, navy backdrop and hull are **directly from the original generated artwork**; only masking, crop and resolution conversion have changed.
- `approved-icon/icns/portside-approved-original.icns`: generated from that same PNG.
- `icon-composer/AppIcon.icon`: an Icon Composer `.icon` package containing a single PNG layer of the approved illustration for maximum fidelity. The JSON uses `supported-platforms.squares: "shared"` rather than the invalid v1 array.
- `icon-composer/import-original-layers`: separate images with original pixels, for manual import if desired. **Importing individual layers and applying dynamic materials may alter the original appearance**.
- `vector-reconstruction/`: actual editable SVG paths, but reconstructed from the render; these are NOT pixel-exact and must not be substituted for the approved original in production without visual signoff.
- `wordmarks/`: raster versions use the exact approved icon; editable SVG wordmarks use reconstructed geometry.
- `presentation/`: two-page updated brand reference.
- `reference/`: original unaltered concept board and the original icon with shadow on its white studio background.

## Icon Composer caveat
Apple has not publicly documented its complete `icon.json` schema. This file structure follows known examples, but **has not been opened or validated by Apple's macOS-only app or `actool`**. If your Icon Composer build refuses the package, create a new document in Icon Composer and import the approved PNG (`approved-icon/png/portside-approved-original-1024.png`). That ensures the visual design stays unchanged. Save the document to create an official `.icon`.

## Color reference (original render sampled)
- Navy: `#10283F` (supporting palette, original has subtle lighting gradient)
- Cream: `#F4EEDF` (supporting palette, original has soft warm highlights)
- Orange: `#F06A42` (supporting palette, original hull contains gradients)

Note: the 1024 icon is enlarged from a roughly 518px-wide icon in the original board. It is an exact-source design, not a newly generated high-res raster. The 3D shading does not have exact editable vector equivalents.
