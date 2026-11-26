# Keeping the README current

The README is the first page people see. It is mostly visuals and short tables. Detail lives in `docs/FEATURES.md` and `docs/PRIVACY.md`. Update it in the same PR as the feature, once the feature is built and working.

## What to touch

| You built | Update in README.md | Also update |
| --- | --- | --- |
| A new surface (a new panel, shelf or tool) | A row in the Features table, a card in the grid, a `<details>` block | `docs/images/surfaces.svg` if it has a fixed place on screen |
| A feature inside an existing surface | One bullet (or table cell) in that surface's `<details>` block; the card only if it shows something now wrong | `docs/FEATURES.md` |
| A feature big enough to show on its own (a new style, mode or cross-surface feature like the music visualizer or agent status) | Its own Features row, card and `<details>` block, even if it lives inside another surface's Settings | `docs/FEATURES.md` |
| A change in status (experimental to on, off by default to on) | The Status column | `docs/CHECKLIST.md` |
| Something from Planned | Remove it from Planned; add it as above | |
| A new network host, permission, or file written | The Privacy tables | `docs/PRIVACY.md` (full text) |
| A new build or debug command | The Build from source command table | `docs/BUILD.md` |
| A new user-facing doc | The Docs table, in the right column | |

Never list a feature that is not in the code. Something half built stays in Planned, or gets the Experimental or Preview status.

## Style

- **Show, then tell.** Prefer a table row, a card or a diagram over a paragraph. No paragraph in README.md over three lines.
- **One line per bullet**, about 15 words at most. The full sentence goes in `docs/FEATURES.md`.
- **No architecture in the README.** Class names, APIs, timers and private API notes go in `docs/ARCHITECTURE.md`.
- **Keep the `<details>` blocks.** Short lists stay collapsed so the page scans fast. Leave a blank line after `<summary>` and before `</details>`, or GitHub will not render the Markdown inside.
- **Don't rely on `<br>`.** Some Markdown viewers drop it. Use a separate `<p>` for a new line.
- No em dashes (AGENTS.md rule 9).

## Cards

The feature cards and the privacy diagram in `docs/images/*.svg` come from `scripts/readme-cards.py`. Each SVG holds its light and dark colors (`prefers-color-scheme`), so there is one file per card.

1. Edit or add a `card(...)` call in `scripts/readme-cards.py`. Reuse the CSS classes (`panel`, `soft`, `ink`, `accent`, `tint`, `t`, `tm`, `key`) instead of new colors. Brand colors are in `design/design-tokens/portside.css`.
2. Run `python3 scripts/readme-cards.py`.
3. Check the render: `qlmanage -t -s 600 -o /tmp/cards docs/images/<card>.svg` (Quick Look crops it to a square; the card is the top part). Text must stay inside the 440 pt wide card, including the hint line.
4. A new card goes into the grid table in README.md. Keep it two columns with an even number of cards (pair related ones on a row), and add `alt` text that says what the card shows.

`docs/images/surfaces.svg` (the hero diagram) is edited by hand.

## Before you finish

- Links and image paths in README.md resolve (`docs/...`, `design/...`).
- The Features table, the grid and the `<details>` blocks list the same surfaces.
- Say in your report that the README was not checked on GitHub, unless it was.
