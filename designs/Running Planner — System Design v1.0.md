# Running Planner — System Design v1.0

*Approved · v1.0 · October 28, 2026 · iOS-first planner with a backend API; web companion in phase 2*

## 1. Purpose and scope

The product is a **training-plan planner**, not an activity tracker. Runners set goals, get a multi-week plan (or build their own), adjust it freely, carry each workout’s details to their watch, record the session in another app, and import the result so the plan can be reviewed and adjusted.

**The usage loop**

1. Set parameters and goals through a short interview.
2. Get a suggested plan of X weeks (or build one from blank). The plan stays editable at any time.
3. Zoom between a single week and the whole plan, with progress.
4. Before a session, open a dedicated view with everything needed to set up a watch: distance, pace, time, warm-up, cooldown, intervals.
5. Record the session in an external app (Apple Watch Workout, Garmin, Nike Run Club and so on).
6. Import the result into the iOS app.
7. Review and adjust the plan, then keep progressing.

**Non-goals for now:** live tracking, GPS or voice coaching; uploading session data from the web; social features; an Android app (planned for later); AI-generated plans (phase 3).

## 2. Decisions log

| # | Decision | Status |
| --- | --- | --- |
| 1 | Planner-focused product; no live activity tracking | Decided |
| 2 | Separate clients and backend; iOS app is full-featured and the focus of phase 1 | Decided |
| 3 | Phase 2 adds a web planning companion (adjust plan, view progress) that does NOT upload session data | Decided |
| 4 | Backend exposes APIs (authentication, CRUD, etc.) used by both iOS and web | Decided |
| 5 | Users can build a plan from blank or use the built-in rule-based engine, driven by goals and interview-derived fitness level; AI plans possible later | Decided |
| 6 | Rule engine starts with 5K, 10K and half marathon presets, with variations driven by interview answers; users can always build a plan that ignores any rule | Decided |
| 7 | Users can complete the interview and preview a plan before creating an account; an account is needed to save | Decided |
| 8 | The preview uses a stateless, unauthenticated generate endpoint | Decided |
| 9 | Offline edits queue locally and sync later | Decided |
| 10 | Rule-generated plans start conservative and are always suggestions; users adjust at will based on how they feel before, during or after sessions | Decided |
| 11 | Pace is expressed in minutes per km (for example 6:30/km) | Decided |
| 12 | A native Android client can come later and import data through the same backend APIs | Decided |
| 13 | An unsaved preview draft is kept on the device for 24 hours | Decided |
| 14 | Simple strength training is part of the plans | Decided |
| 15 | Cross-training is handled by a free-form custom session that users can add now; no dedicated cross-training plans | Decided |
| 16 | The "no race / build a running habit" goal is dropped for v1; rule-based goals are 5K, 10K or half marathon (blank plans may have a custom goal or none) | Decided |
| 17 | Sign in with Apple plus email sign-in in phase 1, so one account works on iOS, web and later Android | Decided |
| 18 | Minimum iOS 17 (watchOS 10 for watch send), as required by WorkoutKit | Decided |
| 19 | Re-running the interview mid-plan regenerates future weeks only, keeps past and user-owned sessions, and is delivered as a proposal | Decided |
| 20 | Sessions are stored as local calendar dates; imported activities match by the user’s local date at the time | Decided |
| 21 | Native-only activity uploads are enforced server-side with client-type scopes plus App Attest | Decided |
| 22 | Review frequency is a user setting: Weekly (user picks the review day), Weekly plus urgent, After every import, or Off. Default is Weekly plus urgent | Decided |
| 23 | Everything else in this document, as approved in v1.0 | Approved |

## 3. Design principles

- **Suggestions, not orders.** Generated plans are starting points. Users can change anything, at any time.
- **No punishment workouts.** A missed or shortened session is never crammed into later days. The engine may propose easing instead.
- **Conservative by default.** The first weeks start below the stated baseline, and paces are shown as ranges.
- **User-owned edits.** Anything a user changes is marked user-owned and is never overwritten by the engine.
- **Show the why.** Every suggested session or change carries a short, human-readable reason.
- **Plans are data.** Blank, rule-based and (later) AI plans all produce the same structure, and every client edits that one structure.
- **Native apps only for activity data.** Only native apps (iOS now, Android later) import and upload sessions; the web never does.

## 4. System overview

**Components**

- **iOS app (phase 1):** full feature set, local store, offline sync queue, HealthKit import, watch handoff. Minimum iOS 17 (watchOS 10 for watch send).
- **Backend API:** authentication, CRUD for plans, sessions, activities, check-ins and proposals, sync, progress aggregates.
- **Plan engine:** a backend service with two operations (generate a plan, propose adjustments). Rule-based first.
- **Database:** system of record.
- **Web companion (phase 2):** plan editing, progress, review. No session upload.

**Data flow**

```
Tracking apps (Watch, Garmin, Nike, ...) -> Apple Health
                                              |
                                              v
          iOS app (local store + sync queue) <-> Backend API <-> Database
                                                       |
                                                       +-- Plan engine (generate / propose)
                              Web companion (phase 2) <-> Backend API
```

Activity data enters the system only through native apps that can read the phone’s health data: iOS in phase 1, Android later through the same API. The web companion reads it.

## 5. Domain model

All distances are stored in metres and durations in seconds. Pace is stored as seconds per kilometre and always shown as minutes per kilometre (for example 6:30/km). Every synced entity has a client-generated UUID, a revision counter, an updatedAt time and a deletedAt tombstone.

**Plan**

| Field | Notes |
| --- | --- |
| goal | Type (5K, 10K, half marathon, custom, none), optional date, optional target time |
| startDate, weekCount | Plan span |
| source | blank, rules or ai |
| engine | Preset id, engine version and an interview snapshot (empty for blank plans) |
| adaptive | Whether the engine may propose adjustments. On by default for rule-based plans, off for blank plans |

**Week** (lightweight): index, phase label (base, build, peak, taper), notes. Session dates are local calendar dates (no time zone), and imported activities match by the user’s local date when the activity started, so travel does not break matching.

**Session**

| Field | Notes |
| --- | --- |
| date, type | Easy, long, intervals, tempo, strength, rest or custom |
| status | planned, done, skipped |
| owner | system or user (user-owned sessions are never changed by the engine) |
| steps | Ordered list of steps (below). Totals for duration and distance are derived, never stored separately |
| notes | Free text |

**Step** (recursive; the same structure drives the editor, the watch handoff view and the engine output)

| Field | Notes |
| --- | --- |
| kind | warm-up, work, recovery, cooldown, repeat, or exercise (strength sessions only, see below) |
| goal | time, distance or open, with a value |
| target | pace range, heart-rate range, effort or none |
| repeat | Only for kind = repeat: a count and child steps (for example 4 × work + recovery) |

**Strength steps.** A strength session uses exercise steps instead: an exercise from a small curated library (bodyweight and dumbbell movements), sets, reps or a duration, rest, and an optional load note. Targets are effort-based, with no pace or heart-rate target. As with any session, totals are derived from the steps.

**Custom sessions.** A custom session is free-form and is how users add cross-training such as cycling or swimming: a title, an optional activity label, a time or distance goal, an optional effort level (easy, moderate or hard) and notes. The engine never generates or changes custom sessions. They are user-owned, show on the plan, count toward total training time rather than running volume, and use their effort level so the validators can still warn about back-to-back hard days.

**Activity** (imported by native clients only): id, source, externalId (dedupe key), startedAt, distance, duration, average and max heart rate, cadence, elevation gain, importedAt. Phase 1 stores summaries only, not routes.

**Match:** links an activity to a session, with a status (suggested, confirmed, extra run, unmatched). Plan-versus-actual deltas are derived.

**CheckIn:** session, when (before or after), overall feel, effort felt, a coarse pain flag and an optional note.

**Proposal:** plan, the plan revision it was based on, creator (rule set version or ai), reason, a list of session-level changes, and a status (pending, accepted, dismissed, stale).

**Profile:** display mode for targets (pace in min/km, heart rate or effort), derived pace ranges with their provenance (from a race time, estimated, or set manually), scheduling preferences, and review settings (frequency and review day).

## 6. Plan engine

### 6.1 Interface

- **generate(request) returns a plan draft.** The request holds the interview answers, an optional preset, and today’s date. The response holds the plan, a list of **assumptions** (for example, the easy pace estimate and what it was based on) and a list of **warnings** (for example, the plan was shortened).
- **propose\_adjustments(plan, activities, check-ins, today) returns proposals.** It never edits the plan.

Both operations are deterministic for the same inputs. The engine is versioned and each plan records the version that produced it.

### 6.2 Presets and variations

| Preset | Typical length | Key session types |
| --- | --- | --- |
| 5K | 8–12 weeks | Easy runs, short intervals, short tempo, modest long run |
| 10K | 8–14 weeks | Easy runs, intervals, tempo, long run |
| Half marathon | 10–16 weeks | Easy runs, tempo, progressive long run, optional intervals |

*These are starting ranges only. Have a qualified coach review the presets before shipping.*

Variation dimensions are deliberately few:

- **Runs per week:** 3, 4 or 5.
- **Experience tier:** returning or beginner, intermediate, experienced.
- **Plan length:** derived from the goal date, within each preset’s minimum and maximum.
- **Day constraints:** preferred long-run day, unavailable days, one protected rest day.
- **Strength:** on or off, with equipment (bodyweight or dumbbells) when on.

That gives 3 presets × 3 run frequencies × 3 tiers × 2 strength options = 54 base variants, plus boundary cases for plan length and day constraints. All of them can be snapshot-tested.

### 6.3 Pace and target derivation

- With a recent race or time trial, estimate current ability using a standard race-equivalence model and derive ranges for easy, long, tempo and interval running. The specific model is an open decision (see section 12).
- Start the easy ranges on the slower side and show ranges in minutes per km (for example 6:25–7:10/km), never single points.
- Without a recent result, use effort-based targets and prompt for calibration after the first hard effort.
- Heart-rate targets appear only when the user supplies maximum heart rate or zones. They are not inferred.
- Targets must be expressible on a watch: pace or heart-rate ranges, plus time or distance goals.

### 6.4 Invariants and guardrails

Every generated plan must satisfy these. The values are tunable parameters to validate with a coach.

- First week below the stated baseline volume (conservative start).
- Cap on week-to-week volume increases, with a down week every few weeks.
- At least one easy or rest day between hard sessions.
- At least one protected rest day per week.
- Cap on the long run’s share of weekly volume.
- A taper before the goal date.
- Strength (when selected): one or two short sessions a week, placed away from key hard runs and the long run, using a small exercise library reviewed by a qualified coach.

The same validators run on every edit and on custom plans, where they **warn but never block**. Hard errors are reserved for invalid data. This matches the preview-before-apply pattern from the mockup.

### 6.5 Edge cases to define up front

- **Goal date too soon:** do not compress the ramp. Offer a shorter plan only down to a minimum length, otherwise propose a later date or a base-building plan with no race date.
- **Goal date far away:** add a base phase, or start the plan later.
- **Baseline far below the goal:** suggest a different distance or date.
- **Pain or injury flag:** select the cautious variant and show guidance to consult a qualified professional. The engine does not give medical advice.

### 6.6 Adaptation and proposals

Inputs: matches (done, skipped, extra), plan-versus-actual deltas and check-ins. Example rules:

- A missed key session leads to a proposal to drop it, not to reschedule it.
- Repeated sessions that felt much harder than planned lead to a proposal to ease the next week.
- A pain flag leads to a proposal to reduce load, with guidance to seek advice.
- Consistently easy sessions lead to a small progression proposal.

Rules for proposals:

- Proposals never auto-apply. They are accepted or dismissed.
- A proposal becomes **stale** when the plan revision it was based on has changed.
- User-owned sessions are shown but locked unless the user opts in.
- Blank plans have adaptation off by default, with opt-in.

**Re-running the interview mid-plan** calls generate with the new answers, keeps past weeks and user-owned sessions unchanged, regenerates only future weeks, and presents the result as a proposal to accept or dismiss.

### 6.6a Review and its frequency

The **review** closes the loop between plan and reality. It has three parts:

1. **Summary:** planned versus completed sessions, distance and time against plan, key sessions hit or missed, and feel and pain notes from check-ins.
2. **Proposals:** the engine’s suggested changes for the coming weeks, each with a one-line reason, accepted or dismissed one by one.
3. **Loose ends:** activities still waiting in the import inbox, so the summary uses complete data.

| Setting | When the review and proposals appear |
| --- | --- |
| Weekly | Once a week on a day the user picks (default: the last day of the plan week). The review waits on the Next screen until opened |
| Weekly plus urgent (default) | As Weekly, plus an immediate proposal when a check-in has a pain flag or a key session is missed |
| After every import | Proposals after each import sync; the weekly summary still appears on the review day |
| Off | No review screen and no proposals |

Rules that apply in every setting:

- Proposals never auto-apply.
- Re-running the interview always produces a proposal, even when reviews are Off.
- The pain guidance shown at check-in (stop and seek advice) appears whatever the review setting is, since it is safety information, not a plan adjustment.
- Blank plans with adaptation off still get the summary when reviews are on, without proposals.
- The engine runs on the backend, so a review computed after an iPhone sync is also visible in the web companion.

### 6.7 AI later

An AI implementation sits behind the same two operations. Its output passes through the same invariants validator before the user sees it, is marked source = ai, and never writes to a plan directly.

## 7. Backend API outline

Illustrative REST-style routes. Final shapes are to be decided.

| Area | Routes | Notes |
| --- | --- | --- |
| Auth | POST /v1/auth/sign-in, POST /v1/auth/refresh, DELETE /v1/account | Sign in with Apple and email sign-in from phase 1, available on every client |
| Generate | POST /v1/plans/generate | **Unauthenticated and stateless.** Nothing is stored |
| Plans | GET and POST /v1/plans, GET, PATCH and DELETE /v1/plans/{id} | Saving the preview draft is a normal plan create |
| Sessions | PATCH /v1/sessions/{id} | Edits carry the base revision |
| Sync | POST /v1/sync | Batched operations with idempotency keys and a cursor. Returns server changes and conflicts |
| Activities | POST /v1/activities:batch, GET /v1/activities | Write access limited to native clients (iOS now, Android later), enforced server-side by client-type token scopes plus App Attest on iOS; the web client cannot call it |
| Matches and check-ins | PUT /v1/sessions/{id}/match, POST /v1/sessions/{id}/checkins |  |
| Proposals | POST /v1/plans/{id}/proposals:generate, POST /v1/proposals/{id}:accept, :dismiss |  |
| Progress | GET /v1/plans/{id}/progress | Aggregates for the whole-plan view |

**Abuse controls for the unauthenticated generate endpoint**

- Rate limiting by IP and device.
- Consider app attestation (such as Apple’s App Attest) to favour genuine app traffic.
- Strict schema validation and bounds on every input.
- No persistence, and no logging of interview answers (especially the injury flag).
- Bounded compute and response size.

## 8. iOS app behaviour

### 8.1 Onboarding and the pre-account preview

1. Interview of about 8–12 short questions, one per screen, skippable with sensible defaults (see Appendix B).
2. The app calls generate and shows **Your suggested plan**: the whole-plan overview, week 1 and one sample session, with the assumptions and warnings listed. The preview is read-only, and changing an answer regenerates it.
3. **Save your plan** asks the user to sign in, then creates the plan through the normal API.
4. Interview answers and the draft live only on the device until the user saves. An unsaved draft is kept on the device for 24 hours and is then deleted.

### 8.2 Offline and sync

- The local store is what the UI reads and writes. Every change is appended to a queue with an idempotency key and the base revision of the entity.
- When online, the app pushes the queue, then pulls changes since its cursor.
- Conflicts are detected per session by revision, not by device clocks. If only one side changed a session since the last sync, apply it. If both changed it, ask the user to keep theirs or the other version.
- Deletions are tombstones, so a removed session cannot reappear.
- Pending proposals are marked stale when the plan revision they were based on has moved.

### 8.3 Importing activities

- With the user’s permission, the app reads running, strength and other workout types (for custom sessions such as cycling) from Apple Health since the plan started and dedupes them (see the Garmin caveat below).
- Each new activity gets a suggested match by date, type and duration, shown in an **import inbox** where the user confirms or reassigns it.
- Handle extra runs, unmatched activities, two runs in one day and missed sessions. Strength and custom sessions match by date and duration only.
- After a match is confirmed, show plan versus actual and prompt for an after-session check-in.
- What reaches Health depends on what each tracking app writes there, so verify the data on real devices (Apple Watch, Garmin and Nike). Rep-level comparison may not be possible from imported summaries, so start with session-level comparison.
- **Garmin caveat.** Garmin Connect can write workouts to Apple Health, but Garmin forum reports describe workouts being re-written on every sync ([report 1](https://forums.garmin.com/apps-software/mobile-apps-web/f/garmin-connect-mobile-ios/430872/bug---garmin-connect-sync-erasing-training-load-ratings-in-apple-health---sync-overwriting-activities-each-time/2053404)) and syncs stalling after app updates ([report 2](https://forums.garmin.com/apps-software/mobile-apps-web/f/garmin-connect-mobile-ios/334152/steps-non-sync-on-apple-health/1622435)). Dedupe on start time, duration and distance, not only the Health record id, and never treat an imported record as final.
- **Later option.** Garmin’s Activity API delivers activity data cloud to cloud to approved developers ([overview](https://developer.garmin.com/gc-developer-program/overview)). That would be a second import route for Garmin users that does not depend on Apple Health. It is a backend integration, not a web upload.

### 8.4 Session view and watch handoff

The session view is a **spec sheet** for the watch:

- Steps listed in the order a watch workout builder asks for them, with repeats grouped.
- Each step shows its goal and target in watch-friendly formats (pace ranges such as 5:45–6:00/km, durations as m:ss). Strength sessions show an exercise checklist with sets, reps and rest.
- A copy or share action for the whole workout as text.
- **Apple Watch send (feasible in phase 1).** Apple’s WorkoutKit (introduced with iOS 17 and watchOS 10) builds a structured custom workout: a warm-up, repeatable blocks of work and recovery steps, and a cool-down. Each step has one goal (time, distance or open) and can carry one alert (pace, heart rate, cadence or power), which maps directly onto our step model. The app can present Apple’s preview screen with an Add to Watch button or, with the user’s permission, schedule workouts into the Workout app. Scheduling shows the next and previous seven days and syncs up to 15 workouts at a time, so the app should sync a rolling window of upcoming sessions and keep it current. It targets the Workout app on Apple Watch, so it only helps users who have one. Source: [Apple WWDC23, Build custom workouts with WorkoutKit](https://developer.apple.com/videos/play/wwdc2023/10016/). That session dates from 2023, so confirm details against the current [WorkoutKit documentation](https://developer.apple.com/documentation/WorkoutKit) before building.
- **Garmin push (depends on API access).** Garmin’s Training API publishes structured workouts and training plans to the user’s Garmin Connect calendar, and they then sync to compatible Garmin devices. It is a cloud API, so calls would come from our backend, not the app, and it could serve web and Android users too. Access is free but limited to approved business developers (see section 12). Source: [Garmin Training API](https://developer.garmin.com/gc-developer-program/training-api).
- **Manual fallback.** The spec sheet stays a first-class path for Garmin users until access is approved, and for any other watch.
- Quick adjustments before a session (shorter, easier, swap, skip) that work offline and mark the session user-owned, plus an optional before-session check-in.

### 8.5 Screen map

- **Next:** the next workout, this week’s status, and imports waiting for review.
- **Plan:** a Week and Whole plan toggle. Tapping a week in the whole-plan view opens that week.
- **Progress:** adherence, volume trend, key sessions completed, strength sessions completed (counted separately from running volume) and a goal countdown or on-track signal.
- **Goal and settings:** goal, re-run the interview, review frequency and day, target display (pace, heart rate or effort), account, privacy.
- **Drill-downs:** session view, import inbox, review and proposals, plan and session editor (with repeat groups).

## 9. Web companion (phase 2)

- **In scope:** plan and session editing (including repeats), week and whole-plan views, progress (read-only activity data), review and proposals, account management.
- **Out of scope:** importing or uploading sessions.
- **Stale-data honesty:** show when data was last synced from the iPhone, and use clear empty states when no sessions have arrived.
- **Editing model:** online-first, using the same revision rules as iOS so that edits made on the web and queued offline edits on the phone reconcile safely.

## 10. Privacy and health data

- Interview answers stay on the device until the user chooses to save.
- The injury answer is stored as a coarse flag only. Do not collect free-text health details in phase 1.
- Sync summaries only (no GPS routes) in phase 1.
- Follow Apple’s HealthKit rules, including no use of health data for advertising, and provide a clear privacy policy.
- Provide account deletion and data export.
- Encrypt data in transit and at rest.
- Obligations vary by market, so get legal review before launch, including how plan guidance and injury messaging are worded.

## 11. Phasing

**Phase 1: iOS and backend**

1. Domain model, validators and rule engine with snapshot tests.
2. Backend: generate endpoint, auth, CRUD, sync.
3. iOS: interview, pre-account preview, save flow.
4. iOS: week and whole-plan views, plan and session editor with repeats and free-form custom sessions, offline queue.
5. iOS: session spec sheet and Apple Watch send through WorkoutKit (Garmin push once its API access is approved).
6. iOS: Health import, matching and check-ins.
7. iOS: review (summary and proposals) with the four frequency settings.

**Phase 2: web companion** on the same APIs.

**Phase 3: AI-generated plans** behind the same engine interface and validators.

## 12. Risks and open questions

1. **Engine validity.** Presets and invariants need review by a qualified coach or sports scientist, including the strength exercise library.
2. **Pace model.** Choose and document one race-equivalence method for deriving training paces in min/km.
3. **Garmin access.** The Garmin Training API is open only to approved business developers, and a [Garmin forum post](https://forums.garmin.com/developer/connect-iq/f/discussion/436226/connect-developer-program-access-form-unavailable-anyone-got-through-recently/2044098) describes the access request form being unavailable for weeks. Start the application early and keep the manual spec sheet as the fallback.
4. **Health data fidelity.** Imported data varies by tracking app, interval structure may be missing, and Garmin-to-Health syncs have known reliability complaints.
5. **Android later.** The API is client-agnostic, so a native Android client can import data and call the same endpoints. As far as I know, Health Connect is Android’s counterpart to HealthKit. Keep the source and external-ID fields platform-neutral.
6. **Conflict UX.** Keep the keep-mine-or-theirs prompt rare and simple.
7. **Liability framing.** Wording around injury, pain and plan guidance needs legal review.

## Appendix A: Carrying over the mockup review

**Keep**

- The tone: no punishment workouts, a protected rest day.
- The block chart (width shows duration, height shows effort).
- Preview-before-apply with plain-language warnings.
- Plan-versus-actual summaries and the accessibility foundations.

**Change**

- Open on the next workout, not hero copy.
- Rebuild the session view as a watch spec sheet with pace or heart-rate targets and repeat groups. Fix the interval maths so reps have their own target pace and totals come from one source.
- Add the whole-plan zoom with progress and week navigation.
- Replace the manual log form with the import inbox, keeping manual entry as a short fallback.
- Lead with plain-language effort labels, with RPE secondary.
- Remove the stopwatch, voice cues and Guided tags.
- Navigation becomes Next, Plan, Progress and Goal and settings, with Session as a drill-down.
- Use a compact week list on phones, and raise small touch targets (chart segments, tooltips) to at least 44 points.
- Replace dead-end placeholders in Pace and HR modes with clear unavailable states.
- Remove prototype disclaimers from UI copy and make the sample data self-consistent.

## Appendix B: Interview v0

1. Goal: 5K, 10K or half marathon?
2. Goal date and goal time (both optional).
3. A recent run or race from the last 4–6 weeks: distance and time, or not sure.
4. Average weekly running distance over the last 4 weeks.
5. Longest run in the last 4 weeks.
6. How long you have been running regularly.
7. How many days a week you want to run, and which days are unavailable.
8. Preferred long-run day.
9. Any current pain or injury? Yes or no only. Yes selects the cautious variant and shows guidance to consult a professional.
10. Do you want strength sessions in the plan, and what equipment do you have (bodyweight or dumbbells)?
11. How you want targets shown: pace in min/km, heart rate or effort.
12. Maximum heart rate or zones, if known (optional).
