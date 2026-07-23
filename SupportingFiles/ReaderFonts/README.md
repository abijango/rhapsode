# Reader fonts

Bundled typefaces for the Foliate EPUB reader (`rhapsode://reader/fonts/…`).
The selectable list is **data-driven** in `Sources/Ebook/ReaderFontCatalog.swift`
— add a preset + files here; no bridge switch cases required.

| Family | Files | License |
|--------|--------|---------|
| **Literata** | `Literata-*.ttf` | OFL |
| **Bitter** | `Bitter-*-Variable.ttf` | OFL — `OFL-Bitter.txt` |
| **Vollkorn** | `Vollkorn-*-Variable.ttf` | OFL — `OFL-Vollkorn.txt` |
| **PT Serif** | `PTSerif-*.ttf` | OFL — `OFL-PTSerif.txt` |
| **Roboto Slab** | `RobotoSlab-Variable.ttf` | Apache 2.0 — `LICENSE-RobotoSlab.txt` |
| **Atkinson Hyperlegible** | `AtkinsonHyperlegible-*.ttf` | OFL (Braille Institute) |

Sources: [google/fonts](https://github.com/google/fonts) (`ofl/*`, `apache/robotoslab`).

**Not bundled:** Merriweather full variable faces are ~4.5 MB each — too large for the IPA; add a static subset later if needed (catalog already supports more rows).
