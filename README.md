# FRED Ultra

A powerful macOS application for exploring and visualizing economic data from the Federal Reserve Economic Data (FRED) service.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

### Data Discovery
- **Search** thousands of economic data series from FRED
- **Favorites** - Save frequently accessed series for quick access
- **Recent searches** - Quickly revisit your previous queries

### Visualization
- **Interactive Charts** - View time series data with smooth line and area charts
- **Multi-series comparison** - Overlay multiple data series on a single chart
- **Date range filtering** - Focus on specific time periods (1 month to all time)
- **Hover tooltips** - See exact values by hovering over the chart

### Data Analysis
- **Statistics panel** - View key metrics including:
  - Count, min, max, mean, median
  - Standard deviation
  - Latest value and change
- **Data table** - Browse raw observation data in a sortable table format

### Export & Share
- **CSV export** - Download data in comma-separated format
- **JSON export** - Download data in structured JSON format
- **Copy to clipboard** - Quickly copy data for use in other applications

## Requirements

- macOS 14.0 (Sonoma) or later
- A free FRED API key (get one at [fred.stlouisfed.org](https://fred.stlouisfed.org/docs/api/api_key.html))

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/FRED-Ultra.git
   ```

2. Open `FRED-Ultra.xcodeproj` in Xcode

3. Build and run (⌘R)

4. Add your FRED API key in Settings (⌘,)

## Getting a FRED API Key

1. Visit [FRED API Key Registration](https://fred.stlouisfed.org/docs/api/api_key.html)
2. Create a free account or log in
3. Request an API key
4. Copy the key and paste it in the app's Settings

## Usage

### Searching for Data

1. Use the search bar in the sidebar to find economic data series
2. Search terms can include:
   - Economic indicators: `GDP`, `inflation`, `unemployment`
   - Specific series IDs: `UNRATE`, `CPIAUCSL`, `DGS10`
   - Descriptive terms: `interest rates`, `housing starts`

### Viewing Data

1. Click on a series in the search results to view its data
2. Use the tab bar to switch between:
   - **Chart** - Visual time series representation
   - **Data** - Table of observations
   - **Statistics** - Summary statistics

### Comparing Series

1. Click the "+" button in the toolbar
2. Search for and select additional series
3. Both series will be displayed on the same chart
4. Remove comparison series by clicking the "x" next to them

### Managing Favorites

- Click the star icon to add/remove a series from favorites
- Access favorites from the sidebar
- Right-click for additional options

### Exporting Data

1. Click the export button in the toolbar
2. Choose your format (CSV or JSON)
3. Select a save location

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Settings | ⌘, |
| Refresh | ⌘R |
| Export CSV | ⇧⌘E |

## Architecture

The app follows the MVVM (Model-View-ViewModel) architecture:

```
FRED-Ultra/
├── Models/
│   └── FREDModels.swift       # Data models and types
├── Services/
│   └── FREDService.swift      # API client and data services
├── ViewModels/
│   ├── SearchViewModel.swift  # Search logic
│   └── SeriesDetailViewModel.swift  # Detail view logic
└── Views/
    ├── ContentView.swift      # Main navigation
    ├── SeriesDetailView.swift # Chart, table, stats views
    └── SettingsView.swift     # App configuration
```

## API Reference

This app uses the [FRED API](https://fred.stlouisfed.org/docs/api/fred/). Key endpoints:

- `series/search` - Search for data series
- `series/observations` - Get data points for a series
- `series` - Get series metadata

## Privacy

- Your API key is stored locally on your device using UserDefaults
- Search history and favorites are stored locally
- No data is sent to third parties (only to FRED's official API)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Federal Reserve Bank of St. Louis](https://www.stlouisfed.org/) for providing the FRED API
- Built with [SwiftUI](https://developer.apple.com/xcode/swiftui/) and [Swift Charts](https://developer.apple.com/documentation/charts)

## Support

If you encounter any issues or have questions:

1. Check the [Issues](https://github.com/yourusername/FRED-Ultra/issues) page
2. Create a new issue if your problem isn't already reported
3. Provide as much detail as possible (macOS version, error messages, steps to reproduce)

---

Made with ❤️ for economic data enthusiasts
