---
name: next-task
description: Pick the next unblocked task from docs/backlog.md, plan it, build it test-first, and hand off to /ship.
---

1. Read `docs/backlog.md`. Pick the first unticked task whose phase gate is passed and whose `needs` are ticked.
   If the user named a task, use that one. If nothing is unblocked, say which gate is waiting on the human and stop.
2. Read what the task points to: `spec/openapi.yaml`, the system design sections, the `DK-*` screen files.
3. Write a short plan (files, tests to add) as your first message. Continue without waiting unless the task is marked `ask first`.
4. Write failing tests first and run them to see them fail. Then write the code until they pass.
5. Tick the task in `docs/backlog.md` in the same branch.
6. Run `/ship`.
