# Dark theme screens

HTML source of the 11 dark boards ("The original design in a dark theme") from the Claude Design canvas
"Running Planner iOS": https://claude.ai/artifact/MziiCTxk76h3b735qNXdGj
(same canvas as https://claude.ai/code/artifact/aa05df7b-81f3-483b-8fdb-2aa927762da0).

They are copies for agents to read (colours, spacing, copy, layout are in the inline styles). They were written for
the canvas runtime (`support.js`, not in the repo), but they are plain HTML with inline styles, so a browser renders
them without it. If the canvas changes, re-export these files; the canvas is the master.

Reference images for iOS snapshot tests are in `png/`: one `DK-<Name>.png` per board, 390 pt wide at @3x
(1170 px), as tall as the board. After changing a board, re-render with `bash scripts/export-boards.sh` (headless
Chrome, needs the network for Google Fonts). `scripts/test/design-pngs.test.sh` checks every board has its PNG.
