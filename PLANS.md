# FRED Ultra — Repair, Optimise, Complete

## Objective
Take the checked-in FRED macOS client from "builds and launches" to a correct, fast, and
honest research tool: fix the defects that survived the previous pass, remove the wasteful
network behaviour, make the analytics defensible, and document what actually ships.

## Findings that shaped the plan
The project built, but a close read of every source file found defects the build could not
catch:

1. Date windows were anchored to the current date, so every discontinued series charted
   empty at anything other than "All Time".
2. Changing the date range refetched the series over the network, even though FRED returns
   the entire history in one request.
3. A single failing comparison series aborted the whole batch load and blanked the chart.
4. A cancelled search left `isLoading` stuck at `true`, so the sidebar spun forever.
5. Favorites that failed to open logged an error and did nothing visible.
6. Statistics substituted sentinel values (`firstValue == 0 ? min : firstValue`) instead of
   reporting that a metric was undefined.
7. Standard deviation printed unscaled beside scaled means: "$29.0T" next to "1,234.56".
8. Differences between percentages were labelled "%" rather than percentage points.
9. `UnitDescriptor` and `NumberFormatter` were reconstructed per value, per render, for
   every row of a table that was itself rebuilt on every state change.
10. The Xcode project carried a dangling build file that rendered as "(null) in Resources".
11. `xcodebuild` scripts failed outright when the active developer directory pointed at the
    Command Line Tools.
12. Two UI tests were unconditionally skipped, which made a green run mean nothing.

## Execution phases
1. **Correctness** — repair each defect above, with a regression test per behaviour.
2. **Architecture** — split the model layer into DTOs, units, analytics, and display types;
   split services into API client, settings, and export; add a command centre so menu items
   can be disabled rather than firing into the void.
3. **Performance** — fetch full history once and window locally; memoise unit parsing;
   build table rows lazily; downsample chart marks with LTTB above a budget.
4. **Analytics** — add Level / Change / % Change / YoY / Index transforms computed on full
   history, moving averages scaled to the series cadence, correlation between compared
   series, drawdown and z-score.
5. **Hardening** — Keychain credential storage with migration, bounded retries, forgiving
   decoding, Swift 6 language mode.
6. **Documentation** — rewrite README, continuity files, and the feature list against the
   shipped behaviour.

## Acceptance criteria
- Builds warning-free under the Swift 6 language mode.
- Every defect above has a test that fails against the old behaviour.
- Changing the window or transform issues no network traffic.
- Undefined statistics report `n/a` rather than a placeholder.
- Units labels describe the values each surface actually renders.
- Documentation states what ships and what is still unverified.
