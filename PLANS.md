# FRED Ultra Overhaul Plan

## Objective
Turn the current broken FRED macOS client into a stable, desktop-native data exploration app with accurate analytics, clearer structure, improved observability, and documentation that matches the shipped behavior.

## Current Reality
- The checked-in code does not build.
- The Xcode project contains duplicate compile source entries.
- Documentation overstates completeness.
- The app structure is still small enough to refactor safely in one focused rescue pass.

## Execution Phases
1. Baseline repair
   - Remove duplicate declarations and invalid project source entries.
   - Get `xcodebuild` back to green for the app target.
   - Run tests to surface the next layer of failures.
2. Architecture cleanup
   - Keep services/view models as the stateful core.
   - Split the root UI into clearer macOS surfaces: onboarding, sidebar/workspace, and detail dashboard.
   - Narrow AppKit usage to save/export and platform polish.
3. Feature completion
   - Improve search, favorites, and recent-search workflow.
   - Add richer data insights and comparison handling.
   - Improve exports, clipboard, and discoverability.
4. Telemetry and verification
   - Add unified logging around search, detail loading, export, and favorites.
   - Verify build, test, and smoke scenarios.
5. Documentation and delivery
   - Update README and continuity files.
   - Push only if a real Git remote is configured and push succeeds.

## Acceptance Criteria
- The app builds cleanly with `xcodebuild`.
- Core workflows are operational: onboarding, search, detail loading, comparison, export, settings.
- Useful calculations and metrics are visible in the detail experience.
- Documentation is accurate and specific.
- Remaining risks are explicitly documented if any part cannot be fully verified.
