# Design notes (dark theme)

Pulled from the 11 `designs/dark/DK-*.dc.html` boards of the Claude Design canvas "Running Planner iOS".
The HTML files are the source of truth; this page is a summary. Backlog task 1.4 extends it into a full
handoff spec (component states, screen-to-endpoint map).

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
- Minimum touch target 44 pt; primary buttons 52 to 56 pt tall.
- Tabs: Next, Plan, Progress, Goal.

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
