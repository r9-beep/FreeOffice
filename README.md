# FreeOffice

<p align="center"><img src="docs/icons/icon-launcher.png" width="64" alt="launcher"> <img src="docs/icons/icon-writer.png" width="64" alt="writer"> <img src="docs/icons/icon-sheets.png" width="64" alt="sheets"> <img src="docs/icons/icon-slides.png" width="64" alt="slides"> <img src="docs/icons/icon-poster.png" width="64" alt="poster"> <img src="docs/icons/icon-data.png" width="64" alt="data"> <img src="docs/icons/icon-diagrams.png" width="64" alt="diagrams"> <img src="docs/icons/icon-planner.png" width="64" alt="planner"> <img src="docs/icons/icon-reader.png" width="64" alt="reader"> <img src="docs/icons/icon-math.png" width="64" alt="math"></p>

A personal office suite for macOS, written in Swift and SwiftUI with Liquid Glass. Nine apps, one launcher, no accounts, no subscriptions, and everything stays on your Mac (or your own NAS).

| | App | What it's for |
|---|---|---|
| **Fw** | Writer | Documents: styles, lists, Markdown shortcuts, images, DOCX/PDF/HTML export |
| **Fs** | Sheets | Spreadsheets: 100+ functions, multiple sheets, charts, XLSX import/export |
| **Fl** | Slides | Presentations: themes, a presenter view, PDF/PNG/HTML/PPTX export |
| **Fp** | Poster | Posters, flyers and social cards on a free canvas |
| **Fd** | Data | Databases: typed fields, grid/board/card views, linked tables, a SQL engine, Excel/CSV/JSON import |
| **Fg** | Diagrams | Flowcharts, org charts, mind maps and system sketches with connectors that stay attached, auto-layout, and text-to-diagram |
| **Fm** | Planner | Calendar, tasks and a Gantt timeline, with repeating events and `.ics` import/export |
| **Fr** | Reader | PDFs: highlight, annotate, draw, sign, fill in forms, rearrange pages |
| **Fx** | Math | A notebook with a calculator, your own functions, calculus helpers, typeset LaTeX equations and graphs |

The launcher (**Fo**) gathers every app in one window with tabs, templates, a Learn section, and an in-place updater. Each app also runs on its own.

## Screenshots

| | |
|---|---|
| ![Diagrams](docs/screenshots/diagrams-mindmap.png) | ![Planner](docs/screenshots/planner-month.png) |
| ![Timeline](docs/screenshots/planner-timeline.png) | ![Reader](docs/screenshots/reader.png) |
| ![Math notebook](docs/screenshots/math-notebook.png) | ![Math graphs](docs/screenshots/math-graphs.png) |

## Things that tie it together

- **`@` mentions.** Type `@` in almost any text field to link a document from any other app. Hover the link for a live preview of that document; click it to open.
- **FreeOffice Cloud.** Point the suite at a folder on a NAS or network share and your documents save there (newest file wins, nothing is deleted by a sync).
- **Media panel.** Free stock photos from Openverse (public-domain and CC0 by default, with credit lines added automatically for CC BY), every SF Symbol icon, generated backgrounds, and your own image library — in Poster, Slides, Writer and Diagrams.
- **Themes.** Colourful, Dark, Plain white and Plain dark.
- **Undo and redo everywhere**, and the full macOS font library in every text-heavy app.

## Requirements

- macOS 26 (Tahoe) or later: the interface uses Liquid Glass.
- To build: Xcode command line tools (`swiftc`).

## Build

```bash
./build.sh
```

This builds all ten apps into `dist/` (`FreeOffice.app` plus one app per tool). Set `VERSION` and `BUILD` in the files of the same name.

To produce a release zip and an update feed that the in-app updater can read:

```bash
./release.sh --bump <folder> "Release notes"
```

## Updates

The apps check this repository's latest release for new versions (Updates ▸ Update source, shown in each app). Each release needs the zip **and** `appcast.json` attached; see the comment at the top of `release.sh`.

## Opening the apps

The apps are ad-hoc signed, not notarised. The first time you open one, right-click it and choose **Open**. If macOS still refuses, remove the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/FreeOffice.app"
```

## Files

Documents are plain JSON in `~/Library/Application Support/FreeOffice/` (`office__<app>__<id>.json`). Reader keeps its PDF beside its document as `office__reader__<id>.pdf`. Settings live in `.config.json` in the same folder.

## Layout

- `mac/` — the Swift sources (one editor per app, plus shared engines: spreadsheet formulas, SQL, diagram routing and layout, math parser and typesetter)
- `tools/icon.swift` — generates the black-on-white "Fo / Fw / Fs…" icons
- `build.sh`, `release.sh` — build and release scripts
- `*.html`, `common.js`, `style.css` — the original browser prototypes this started as

## Licence

[Mozilla Public License 2.0](LICENSE). Source files carry the standard MPL notice.
