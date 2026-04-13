# FRED Ultra

FRED Ultra is a native macOS app for searching, comparing, and exporting Federal Reserve Economic Data (FRED) series. It is built with SwiftUI and Swift Charts and is designed for desktop research workflows instead of a simple single-series viewer.

## What the app does

- Guides first-time users through entering and validating a FRED API key.
- Searches FRED series with debounced queries, recent searches, and favorites.
- Opens a series dashboard with:
  - headline metrics for the latest reading, latest change, period change, and annualized drift
  - an interactive chart
  - a raw observation table
  - insight cards and series metadata
- Supports multi-series comparison.
  - When multiple series are loaded, comparison mode can rebase each series to `100` at the start of the selected range so series with different units can still be compared honestly.
- Exports the current main-series observations as CSV or JSON.
- Copies the visible observation set to the clipboard.
- Includes lightweight unified logging for search, settings, detail loading, and export actions.

## Requirements

- macOS 15 or later
- Xcode 16 or later for local development
- A free FRED API key: [FRED API key docs](https://fred.stlouisfed.org/docs/api/api_key.html)

## Project structure

```text
FRED-Ultra/
├── FRED-Ultra/
│   ├── Models/
│   │   └── FREDModels.swift
│   ├── Services/
│   │   └── FREDService.swift
│   ├── Support/
│   │   └── AppLogger.swift
│   ├── ViewModels/
│   │   ├── SearchViewModel.swift
│   │   └── SeriesDetailViewModel.swift
│   ├── Views/
│   │   ├── SeriesDetailView.swift
│   │   └── SettingsView.swift
│   ├── ContentView.swift
│   └── FRED_UltraApp.swift
├── FRED-UltraTests/
├── FRED-UltraUITests/
├── script/build_and_run.sh
├── init.sh
└── handoff.md
```

## Core architecture

- `FRED_UltraApp.swift`
  - App entry point, command menu, settings scene, and app lifecycle logging.
- `ContentView.swift`
  - Root workspace. Shows onboarding when no API key is present, otherwise displays the sidebar and detail workspace.
- `FREDModels.swift`
  - FRED API models, chart/table presentation models, export enums, formatters, and statistics/insight types.
- `FREDService.swift`
  - User defaults-backed settings manager, async FRED API client, and export service.
- `SearchViewModel.swift`
  - Debounced search lifecycle, loading state, and recent-search persistence.
- `SeriesDetailViewModel.swift`
  - Observation loading, comparison/rebased chart data, statistics, insight generation, and export/copy actions.
- `SeriesDetailView.swift`
  - Desktop detail experience for overview, data table, and insight surfaces.
- `SettingsView.swift`
  - API-key validation and local data management.

## Running the app

### Xcode

1. Open `FRED-Ultra.xcodeproj`.
2. Select the `FRED-Ultra` scheme.
3. Build and run.

### Terminal

Build and launch the app:

```bash
./script/build_and_run.sh
```

Verify it launches:

```bash
./script/build_and_run.sh --verify
```

Stream app logs:

```bash
./script/build_and_run.sh --logs
```

## Verification commands

Build:

```bash
xcodebuild -project FRED-Ultra.xcodeproj -scheme FRED-Ultra -sdk macosx build
```

Run the unit tests:

```bash
xcodebuild -project FRED-Ultra.xcodeproj -scheme FRED-Ultra -sdk macosx test -only-testing:FRED-UltraTests
```

Project smoke script:

```bash
./init.sh
```

## Command shortcuts

- `⌘R` refreshes the current series detail view.
- `⇧⌘E` exports CSV from the current series detail view.
- The `Data` menu also exposes JSON export.

## Notes

- Favorites, recent searches, and the API key are stored locally on the Mac using `UserDefaults`.
- The app talks only to the official FRED API.
- GitHub remote configuration is not bundled in the repository. If you want to push the project, add a remote and authenticate normally for your environment.
