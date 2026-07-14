# ReaPack Repository — Frank Acklin Scripts

Dieses Repo ist der ReaPack-Index für Franks REAPER-Skripte (RAPID, Rea-Sixty, ReaMark,
TotalReaper). `index.xml` wird von der GitHub Action generiert — **nie von Hand editieren**.

ReaPack-URL für Nutzer:
```
https://raw.githubusercontent.com/USER/REPO/main/index.xml
```

## Struktur

```
repo/
├── .github/workflows/reapack.yml
├── ScriptName/
│   └── ScriptName.lua
└── index.xml (auto-generiert)
```

Skripte müssen in **Unterverzeichnissen** liegen (z.B. `RAPID/RAPID.lua`), nicht im Root.

## Script-Metadata-Header (Pflicht)

```lua
-- @description Script Name
-- @author Author Name
-- @version 1.0
-- @changelog
--   Changes for this version
-- @about
--   # Script Title
--   Markdown description here
-- @link GitHub https://github.com/user/repo
```

`@version` ist **zwingend**. `@provides` ist optional bei Einzeldatei-Skripten.

## GitHub Action (`.github/workflows/reapack.yml`)

```yaml
name: ReaPack Index

on:
  push:
    branches:
      - main

permissions:
  contents: write

jobs:
  index:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y pandoc
          sudo gem install reapack-index

      - name: Build index
        run: |
          git config user.name "GitHub Actions"
          git config user.email "actions@github.com"
          rm -f index.xml
          reapack-index \
            --name "Repository Name" \
            --url-template 'https://github.com/USER/REPO/raw/$commit/$path' \
            --commit \
            --rebuild \
            . \
            --output index.xml

      - name: Push changes
        run: |
          git push
```

## Fallstricke (teuer erkauft)

- **pandoc muss installiert sein** — sonst schlägt die `@about`-Konvertierung (Markdown → RTF) fehl.
- **`--url-template` in einfache Anführungszeichen** — sonst expandiert bash `$commit` und `$path` zu leer.
- **`--rebuild`** regeneriert den vollen Index aus der git-Historie.

---

*Stand 2026-07-14 aus der globalen `~/.claude/CLAUDE.md` hierher verschoben — es ist
ReaPack-Wissen und gehört ins ReaPack-Repo, nicht in jede Session jedes Projekts.*
