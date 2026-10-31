# Design notes (dark theme)

Pulled from the 11 `designs/dark/DK-*.dc.html` boards of the Claude Design canvas "Running Planner iOS".
The HTML files are the source of truth; this page is the handoff summary: tokens, components and their states,
accessibility rules, and which endpoints each screen calls. Sizes are in pt (1 CSS px on the 390-wide boards).

## Tokens

| Token | Hex | Use |
| --- | --- | --- |
| bg | `#1C1A15` | Screen background |
| card | `#27241D` | Cards and rows |
| ink | `#F5F1E6` | Primary text |
| muted | `#ABA597` | Secondary text |
| line | `#3A362B` | Dividers, track of progress bars |
| accent | `#C9411B` | Primary buttons (white text) |
| accent-text | `#FF8A63` | Accent text, active tab |
| accent-soft | `#4A2418` | Selected option background |
| green | `#4FC79A` | Done, on track |
| green-ink | `#0F2A20` | Text and icons on green |
| rest-ring | `#7C7667` | Dashed ring of a rest day in the week strip |
| chip-text | `#FFB59B` | Text on an `accent-soft` chip (the effort chip on Next) |
| yours-text | `#D8D2C2` | "Yours" badge text, on `line` |
| rest-border | `#5C5748` | Dashed border of a rest day's card (Week) |
| segment-track / segment-selected | `#2D2A22` / `#443F33` | Week / Whole plan switch: track and selected segment |
| goal-card / goal-border / goal-text / goal-track | `#33291F` / `#4A3C2B` / `#CFC8B8` / `#4A4638` | Goal card on Whole plan |
| green-soft / green-soft-text | `#1D3A2E` / `#8EE0BF` | Easy badge, goal card |
| amber-soft | `#3B3115` | Notices (review ready, assumptions) |
| blue-soft / blue-text | `#1F2A4D` / `#B7C7F5` | Long-run badge, import icon |
| plum-soft / plum-text | `#35294E` / `#D6C2F5` | Strength |
| tab bar | `#141310` | Bottom navigation background |

Session-shape and chart colours: warm-up and easy `#4C9C80`, fast reps and peak `#F0643A`, build `#E9B949`, taper `#8C9FD8`.

## Type

- Headings: Bricolage Grotesque 700, 28 to 34 pt, letter-spacing -0.02em.
- Body: Inter 400 to 600; 15 to 16 pt body, 13 pt secondary, 11 to 12 pt labels.
- Numbers use tabular figures.

## Shape and touch

- Radii: 24 for large cards, 16 to 20 for rows and buttons, 12 for small buttons, fully round for chips and day dots.
- Minimum touch target 44 pt; primary buttons 50 to 56 pt tall.
- Tabs: Next, Plan, Progress, Goal.
- Screen padding 20 pt at the sides; the boards are 390 × 844 (iPhone 14/15/16).

## Screens

| # | File | Screen |
| --- | --- | --- |
| 1 | DK-Interview | Interview |
| 2 | DK-Preview | Suggested plan preview (no account) |
| 3 | DK-Next | Next |
| 4 | DK-Week | Plan: week |
| 5 | DK-Whole | Plan: whole plan |
| 6 | DK-Progress | Progress |
| 7 | DK-Session | Session spec sheet |
| 8 | DK-Editor | Session editor |
| 9 | DK-Inbox | Import inbox |
| 10 | DK-CheckIn | Plan vs actual and check-in |
| 11 | DK-Review | Weekly review |

## Components and states

Colours are tokens from the table above; raw hex values are ones the boards use without a token name.
Every interactive element also has a **pressed** state (background one step lighter, or 0.7 opacity on
text-only buttons) and a **disabled** state (0.4 opacity, not focusable by VoiceOver as a button).

| Component | Where | Default | Selected or active | Other states |
| --- | --- | --- | --- | --- |
| Primary button | Continue, Save your plan, Open workout, Accept, Save | `accent` fill, white 16–17 pt 600, radius 14–18, 50–56 pt tall, full width | n/a | Loading: label replaced by a spinner, same size, not tappable. Offline: stays enabled when the action can queue (edits, check-ins); disabled with a one-line reason when it needs the network (sign-in, preview) |
| Secondary button | Make it easier, Move or skip, Dismiss, Match to a session | Transparent, 1 pt border `#4A4638`, ink 14–15 pt 600, radius 12–14, 44–50 pt | n/a | As primary |
| Light button | Add as extra run (Inbox) | `ink` fill, `#1C1A15` text 15 pt 600, radius 14, 50 pt | n/a | As primary; used for the main action inside a card when the screen already has a primary button |
| Text button | Skip, I'd rather build my own plan, Skip for now, Change an answer | Muted 15 pt 600, no border, 44 pt tall | n/a | Pressed: ink colour |
| Back link | Inbox, Next (top left of drill-downs) | Chevron + previous screen name, ink 16 pt 600, 44 pt tall | n/a | n/a |
| Option card | Interview answers | `card` fill, 2 pt `line` border, radius 20, 76 pt tall; big label in Bricolage 30 pt | `accent-soft` fill, 2 pt `#F0643A` border, check icon in `accent-text`, secondary text `#E8B8A6` | Single choice per question; multi-choice questions (days) use the same card with a check per card |
| Choice row | Check-in feel (Easier, About right, Harder) | No fill, 1 pt `#4A4638` border on the surrounding card, radius 14, 50 pt | As option card, with check icon | n/a |
| Segmented control | Plan Week / Whole plan, check-in pain Yes / No | Track `#2D2A22` with 3 pt padding, radius 12; segments 40 pt, radius 10, muted 15 pt 600 | Segment fill `#443F33`, ink text | Built with `Picker(.segmented)` styled, or a custom control whose whole 46 pt track is the hit area |
| Chip | Editor session type (Easy, Long, Intervals…), Session quick adjustments | Pill, 1 pt `#4A4638` border, `card` fill, 14 pt 600, 44 pt tall | `accent-soft` fill, `#F0643A` border | n/a |
| Badge | Easy, Long, Yours, On track, Likely match, Extra run | Pill, 11–12 pt 600 caps or sentence case, 3–5 × 9–10 pt padding | Not interactive | Colours by meaning: easy `green-soft`/`green-soft-text`, long `blue-soft`/`blue-text`, strength `plum-soft`/`plum-text`, yours and notices `amber-soft`, on track `green`/`green-ink` |
| Session row | Plan week, Preview week 1 | `card`, radius 16, 64 pt min; day label 11 pt caps, title 16 pt 600, detail 13 pt muted | Today: 2 pt `#F0643A` border, "TODAY" label | Done: green check dot (28 pt) and actuals ("ran 5.1 km at 6:30/km"). Skipped: muted title, "Skipped" badge. Rest: no chevron, "Protected" note. User-owned: "Yours" badge |
| Day dot | Next, This week strip | 36 pt circle; planned: 2 pt `line` border | Today: 3 pt `#F0643A` border, bold label | Done: `green` fill, check in `green-ink`. Rest: dashed border. Missed: muted dash. Whole strip is one VoiceOver element (see below) |
| Step row | Session and Editor watch steps | Numbered 32 pt circle in the step's shape colour, title 16 pt 600, target 13 pt muted, value right-aligned tabular 20 pt | n/a | Repeat group: indented block with "Repeat 5×" header; in the Editor a 44 × 44 − / + stepper and a 36 × 44 drag handle |
| Notice card | Review ready, What we assumed, Heads up, pain guidance | `amber-soft` fill, radius 16–20, ink text | n/a | Pain guidance is never dismissible and shows whatever the review setting (§6.6a) |
| Proposal card | Review | `card`, radius 20; title, one-line reason, before → after (old value struck through, muted) | n/a | Accepted: collapses to a one-line "Applied" row. Dismissed: removed. Stale (plan revision moved): actions disabled, "This suggestion is out of date" and a Refresh text button |
| Inbox card | Import inbox | `card`, radius 24; date and source 13 pt, distance and time 20 pt tabular | Likely match: green check + badge | Extra run, unmatched, two runs on one day (both cards list the same day's session; confirming one moves the other to "Match to a session") |
| Bar chart | Preview, Whole plan, Progress, session shape | Bars coloured by phase (base/easy `#4C9C80`, build `#E9B949`, peak `#F0643A`, taper `#8C9FD8`); planned bars in `line` behind actual bars | Current week: full opacity, others 0.6 | Empty (no data yet): planned bars only. Whole-plan bars are tappable and open that week |
| Progress bar | This week, Sessions done | 8–10 pt, radius full, track `line`, fill `green` | n/a | n/a |
| Tab bar | All top-level screens | `#141310`, 1 pt `line` top border, 4 tabs each 52 pt tall, icon 24 + label 11 pt 600 muted | Active: `accent-text` icon and label | Badge on Next when the inbox or a review is waiting |

### Screen states

Every screen that loads data handles these, using the components above:

- **Loading:** first load only shows a skeleton of the cards (the `card` colour, no shimmer when Reduce Motion is on).
  After that the local store renders at once and the sync happens behind it.
- **Empty:** Next with no plan shows "Set a goal" with a primary button to the interview. The import inbox with
  nothing new shows "All caught up" and the manual-entry link. Progress before the first finished week shows
  planned bars only and "Your first week's progress appears on your review day" (§6.6a: picked by the user, default the last day of the plan week).
- **Offline:** a muted one-line banner under the title, "Offline. Changes are saved and will sync." Edits,
  quick adjustments and check-ins queue (§8.2); sign-in and preview generation show an inline error with Retry.
- **Error:** inline card with a plain sentence and a Retry text button; never a blocking alert for a failed sync.
- **Sync conflict:** a sheet naming the session with two choices, "Keep mine" (primary) and "Use the other
  version" (secondary), both showing the differing fields.

## Accessibility

Checked against WCAG 2.1 AA on the dark boards.

- **Contrast:** every text pair passes 4.5:1. Lowest: white on `accent` buttons 4.9:1, `muted` on `card` 6.3:1,
  phase colours on `card` 4.7:1 or higher. Option cards and dividers use `line` (1.3:1 on `card`), which is fine
  because selection is also shown by the fill, the `#F0643A` border (4.9:1) and the check icon, never by colour
  alone. Keep it that way: status is always a word or an icon too (Done check, Missed dash, badges with text).
- **Touch targets:** 44 × 44 pt minimum. On the boards three controls are drawn smaller and need a larger hit area
  in SwiftUI (`.contentShape` plus `.frame(minHeight: 44)`): the Week / Whole plan segments and the check-in
  Yes / No segments (40 pt; make the 46 pt track the hit area), and the 36 pt day dots on Next if they become
  tappable (today they are display only). The Editor drag handle is 36 × 44; give it the full row height.
- **Dynamic Type:** text uses `Font.custom(_:size:relativeTo:)` so it scales; at accessibility sizes, session
  rows and inbox cards stack the value under the title instead of beside it, and the tab bar keeps icons with
  labels from the large-content viewer. Numbers keep tabular figures.
- **VoiceOver:**
  - Charts are one element each with a summary label, as the boards already write them ("Bar chart of weekly
    running distance over 10 weeks: 16, 18, … kilometres"); the whole-plan chart also exposes each week as an
    adjustable or button element so it can be opened.
  - The day strip on Next reads as one element: "This week: Monday done, Tuesday done, Wednesday today,
    Thursday rest, …".
  - Paces read as words, not punctuation: `6:30/km` is labelled "6 minutes 30 seconds per kilometre"; ranges read
    "6 minutes 25 to 7 minutes 10 per kilometre".
  - Icon-only controls carry labels (Back, Fewer repeats, More repeats, Drag to reorder) and selected options
    add the `.isSelected` trait.
- **Motion:** with Reduce Motion on, no chart grow-in or skeleton shimmer; sheet transitions use cross-fades.

## Screen-to-endpoint map

The app reads and writes its local store first (§8.2). Edits made on a screen are queued and sent through
`sync` (the queued operation kind is in brackets); the single-entity endpoints are named where the app calls them
directly (online-only actions) or so the API tasks know which screen uses them. Names are the spec's
operation ids; `scripts/test/design-notes.test.sh` checks this section against `spec/openapi.yaml`.

| Screen | Reads | Writes and actions |
| --- | --- | --- |
| DK-Interview | Nothing: questions and answers stay on the device | Continue goes to the preview; "build my own plan" starts a blank plan, saved with `createPlan` after sign-in |
| DK-Preview | `generatePlan` (no account; called again when an answer changes) | Save your plan: `startEmailSignIn`, `verifyEmailSignIn`, then `createPlan` |
| DK-Next | Local store, refreshed by `sync`; `listPlans` on first launch to pick the active plan; `listProposals` and `getWeeklyReview` for the review-ready card; inbox count from `listActivities` | Make it easier, Move or skip: `updateSession` (`session.update`) |
| DK-Week | Local store, refreshed by `sync`; `getPlan` on first load of a plan | Add a session opens the editor; marking done or skipped: `updateSession` (`session.update`) |
| DK-Whole | `getPlan`; per-week done distance and on-track badge from `getProgress` | Tap a week opens DK-Week for that week |
| DK-Progress | `getProgress` | None |
| DK-Session | Local store | Shorter, Easier, Swap, Skip: `updateSession` (`session.update`); before-session check-in: `createCheckIn` (`checkin.create`); Add to Apple Watch and Copy steps run on the device (WorkoutKit) |
| DK-Editor | Local store | Save: `updateSession` (`session.update`) or `createSession` (`session.create`); delete: `deleteSession` (`session.delete`); building a plan from blank or changing plan fields: `updatePlan` (`plan.update`) |
| DK-Inbox | HealthKit on the device, uploaded with `importActivities`; the list from `listActivities` with `inbox=true` | Confirm match or Change: `putMatch`; undo a match: `deleteMatch`; Add as extra run, Ignore: `updateActivity`; Add a run manually: `importActivities` with source `manual` |
| DK-CheckIn | The confirmed match and session from the local store | Save: `createCheckIn` (`checkin.create`); with Weekly plus urgent, a pain flag makes the server propose at once (no extra call). After every import: the app calls `generateProposals` after each import sync |
| DK-Review | `getWeeklyReview` (summary, pending proposals, loose ends); `listProposals` | Accept: `acceptProposal`; Dismiss: `dismissProposal`; on the review day the app calls `generateProposals` first if the week has none |
| Goal and settings (no board, task 3.7) | `getProfile`, `listPlans` | `updateProfile` (target display, review frequency and day); edit goal: `updatePlan`; re-run the interview: `generateProposals` with `interview`; delete plan: `deletePlan` (`plan.delete`); export data: `exportAccount`; delete account: `deleteAccount` |

Weekly plus urgent also proposes at once when a key session is missed; the backend does this when the session
becomes missed (task 2.14), so no screen calls it.

Not called from a screen: `getHealth` (monitoring), `refreshToken` (the API client renews tokens when a call
returns 401).
