# Run details, splits, zones, the written summary

Part of the iOS guide (`ios/CLAUDE.md` has the index). Read this before changing `Features/RunDetails`.

## Run details (issue #131)

- No API or spec change: `ActivityFields` already had `elevationGainM`, `getProfile`/`updateProfile` hold `heartRate.maxBpm`, and
  splits, zones and routes never leave the device. `Features/RunDetails/`: `RunDetailsModel` (hero stats, grid, plan chip, plan vs
  actual through `CheckInModel`, the limited-data note), `RunSplits` (per km from distance samples, moving time, fastest and
  slowest of the full km, thin bar = speed relative to the fastest), `HeartRateZones` (bands 60/70/80/90% of the typed max, or the
  profile's own five zones; a reading holds at most 30 s; starting values for H.1), `ZonesSection` (what the zone card shows), all pure
  and unit-tested; `RunDetailsStore` loads Health readings and the profile; `RunDetailsScreen` only draws.
- Opened from "Run details" on each card in All imported runs (`runs.details`) and on the session page's matched run
  (`session.run.details`). A missing stat is left out (never 0 or a dash) and one "Limited data from <source>" note shows.
- **Do not add HealthKit read types** (stepCount, workoutRoute...) casually: `needsAccess()` compares with the whole set, so a new
  type makes it true for every existing user and `load()` silently stops importing on open. Elevation comes from the workout's
  metadata, splits from `distanceWalkingRunning` samples, zones from `heartRate` samples, all already allowed. Cadence stays hidden.
- Backfill: opening details calls `InboxStore.backfill`, which re-reads the workout and re-sends it only when Health now has a
  distance, heart rate or climb the stored run lacks (`HealthWorkoutMapper.fillsGap`). The server merges (never erases a field) and
  keeps the match. It never asks for Health access.
- Max heart rate is asked once on the card (`MaxHeartRateServing`: reads the profile, sends `heartRate` back with the user's zones
  because the section is replaced whole). "Not now" is remembered in UserDefaults (`rundetails.maxhr.declined`); a saved value always
  shows zones. Writing the profile bumps its revision, so a review-settings sheet opened earlier may 409 once on its next save.

- Part 2 (#131): Run details has a weather footer (`RunWeather`, from the workout's metadata on the same read as splits; never
  uploaded; HealthKit's `HKWeatherCondition` is mapped by raw value because the Swift case names differ from the header), a
  splits skeleton (`RunDetailsStore.loading`, only for a Health running run on a device with Health), and the run-side actions
  (`RunMatchModel.actions`: Match, Change session, Unmatch, Back to inbox; a run whose session is gone gets Change only) using
  `SessionPicker` and the store's `rematch`/`unmatch`. The runs list has more doors than the inbox: Next's "Your runs"
  (`next.runs`) and Goal and settings' "Your runs" (`settings.runs`), both opening `RunsScreen` as a `RootView` cover
  (`showRuns`, closed by `requestSignIn`).
- UI tests: an identifier put on a `ScrollView` is not in `otherElements`; look it up with `app.descendants(matching: .any)[id]`.
