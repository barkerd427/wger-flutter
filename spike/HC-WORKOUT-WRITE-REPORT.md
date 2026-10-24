# Spike B: writing wger workout sessions to Health Connect

**Branch:** `claude/hc-workout-write-550i8y` (local commits only, see "Push status").
The requested `spike/hc-workout-write` was refused too: every push from this
session returned HTTP 403 ("Claude doesn't have GitHub access to
barkerd427/wger-flutter"), on both branch names.
**Base:** `master` @ `5dd00d6`. Flutter 3.47.7, the version pinned in
`.github/actions/flutter-common/action.yml`.
**Status:** feasibility prototype, not a feature. No UI wiring, never run on a
device.

## TL;DR

**Feasible and cheap.** No plugin work is needed. The `health_bridge` fork wger
already depends on (`ytsni/health_bridge` v2.0.0, commit `c2494e9`) ships a
purpose-built, idempotent workout export (`writeWorkoutData` /
`lookupWorkoutData`). On Android it writes one `ExerciseSessionRecord` per call,
keyed by `clientRecordId`. A wger session already has what that needs: a
client-minted UUIDv7 id, a start, an end and a routine/day for the title.

The prototype is about 300 lines of Dart plus one manifest line:

| File | What |
|---|---|
| `lib/features/health/models/workout_export.dart` | `WorkoutSession` → export envelope; eligibility rules (`WorkoutExportBlocker`); JSON for the frozen envelope |
| `lib/features/health/providers/health_repository.dart` | `canWriteWorkouts`, `isWorkoutWriteAuthorized`, `ensureWorkoutWriteAuthorized`, `writeWorkout`, `lookupWorkout`, `deleteWorkout` |
| `lib/features/health/providers/health_workout_exporter.dart` | Turns each plugin status into an outcome; device-local ledger; lookup before any retry; delete and rewrite after an edit |
| `android/app/src/main/AndroidManifest.xml` | `android.permission.health.WRITE_EXERCISE` |
| `test/features/health/...` | 33 new tests (mapping, exporter state machine, plugin calls, manifest) |

**Results:** `flutter analyze` finds no issues across the whole project.
`flutter test test/features/health` passes all 163 tests (130 existing + 33
new). `dart format` is clean at the repo's 100-column width. APK build: blocked by
Maven Central rate limiting (HTTP 429); see "Build".

**What a Health Connect workout can't carry:** sets, reps, weights and RiR.
Health Connect gets "Strength training, 09:00–10:15, *Leg day*", and the
training detail stays in wger. That is the main product limitation, not a
technical blocker.

## 1. Plugin analysis (`health_bridge` v2.0.0)

What I read: `lib/src/health_plugin.dart` (`writeWorkoutData`,
`lookupWorkoutData`, `deleteByClientRecordId`), `lib/src/health_workout_export.dart`,
`android/.../HealthWorkoutOperations.kt`, `HealthDataOperations.kt`,
`HealthConstants.kt`, and the README section "Workout export V2".

* **Record written:** `ExerciseSessionRecord(startTime, startZoneOffset,
  endTime, endZoneOffset, exerciseType, title, metadata)`. The record also gets
  an optional `ActiveCaloriesBurnedRecord` when energy is passed. Connect client
  is `androidx.health.connect:connect-client:1.2.0-alpha02`.
* **Activity types:** `STRENGTH_TRAINING` → `EXERCISE_TYPE_STRENGTH_TRAINING`
  and `WEIGHTLIFTING` → `EXERCISE_TYPE_WEIGHTLIFTING`. Both are in the Android
  and iOS allow-lists, and the prototype uses `STRENGTH_TRAINING`.
* **Not supported:** exercise segments (per-exercise blocks with rep counts),
  laps, notes or description, heart-rate series. `title` is the only free-text
  field.
* **Idempotency contract:**
  * `workoutClientRecordId` must be a UUID, and wger session ids are UUIDv7.
  * `clientRecordVersion` must be **0**, so the plugin can't express "updated
    record".
  * Every result carries `submissionCertainty`. A `mayHaveSubmitted` result
    (`verificationRequired`) must be looked up before any resend; only a lookup
    answer of `absent` makes a resend safe.
  * The README asks callers to persist the "envelope" (id, times, offsets,
    title) before the first call and to reuse it verbatim for retries and
    lookups.
* **Permissions:** `requestAuthorization([WORKOUT], permissions: [WRITE])`
  maps to `WRITE_EXERCISE` only. `getAuthorizationSnapshot` reports the exact
  write state per type on Android. On iOS it reports sharing state as well.
* **Delete:** `deleteByClientRecordId(dataTypeKey: WORKOUT, clientRecordId)`
  works and goes to `HealthConnectClient.deleteRecords(class, ids,
  clientIds)`. It returns `false` on any exception.
* **Native error handling is already thorough:** it re-checks permissions after
  a `SecurityException`, maps Remote/IO/cancel failures to
  `verificationRequired` with a platform code, and checks the inserted-id
  count. It is tested against `connect-testing` fakes in the plugin.

Conclusion: wger can call the plugin as is, with no fork or patch needed.

## 2. Mapping a wger session

| Health Connect field | From | Notes |
|---|---|---|
| `clientRecordId` | `WorkoutSession.id` | UUIDv7, minted on the client, never changes. Sessions with no id or a non-UUID id are blocked (`noId`) |
| `startTime` / `endTime` | `datetimeStart` / `datetimeEnd` | Running sessions (`datetimeEnd == null`) are blocked (`notFinished`) |
| zone offsets | `instant.toLocal().timeZoneOffset` per endpoint | Correct across DST. Wrong only if the session was logged in a zone other than the device's current one (see open questions) |
| `exerciseType` | constant `STRENGTH_TRAINING` | wger has no per-routine activity type. `WEIGHTLIFTING` is the alternative |
| `title` | caller-supplied (routine day name), fallback string | Kept free of l10n in the model. The caller passes a localized fallback |
| metadata | `manualEntry`, device `phone` | Times are typed or confirmed in the session form, not sensor-measured. `activelyRecorded` would be arguable only for gym-mode sessions |
| energy | **none** | wger measures no calories. An estimate would flow into Health Connect's daily totals as if measured |

Eligibility guards (`WorkoutExport.check`): empty or reversed interval,
duration > `sessionMaxDuration` (5 h, reusing the app's own limit), end in the
future.

## 3. Exporter behaviour

`HealthWorkoutExporter.export(session)` returns one of `exported`, `upToDate`,
`notEligible`, `unsupported`, `permissionMissing`, `retryLater` or `failed`. It
never asks for permissions.

1. An unconfirmed ledger entry is **settled first** with a lookup that uses the
   *frozen* envelope.
   * `present` / `workoutOnly`: the entry is confirmed.
   * `absent`: the entry is dropped and the export starts fresh.
   * `unavailable` / `inconsistent` or an exception: `retryLater`, and nothing
     is written. A test covers this.
2. A confirmed entry whose interval still matches the session is `upToDate`.
   The title is ignored on purpose: renaming a day doesn't rewrite the record.
3. A confirmed entry that no longer matches (the session was edited) is
   **deleted, then written fresh**. Version 0 can't update a record, and Health
   Connect documents an overwrite only for a *higher* version. If the delete
   fails, the old record and its entry stay put (`retryLater`).
4. A fresh export stores the envelope as unconfirmed *before* calling the
   plugin. The result then decides:
   * `written` / `alreadyPresent` / `writtenWithoutEnergy`: the entry is
     confirmed.
   * `blockedWorkoutPermission`, `transientFailure`, `unavailable`,
     `invalidInput`: nothing was submitted, so the entry is dropped.
   * `verificationRequired`: an immediate lookup.
   * a thrown exception: the entry stays unconfirmed, so the next run looks it
     up.
   * `inconsistentNativeState` (energy without a workout): can't happen with
     energy omitted. It is logged and left as is.
5. `remove(sessionId)` deletes the platform record for a deleted session.

The **ledger** lives in device-local SharedPreferences
(`PreferencesWorkoutExportLedger`, one JSON map). It is deliberately not a
PowerSync table: what one phone wrote to its own Health Connect means nothing
to the server or to another device. The cost is that reinstalling or clearing
the app forgets the ledger. Records written before that then stay in Health
Connect, and a re-export after an edit would add a second record because the
old one is unknown. A fix is to call `lookupWorkout` by session id before the
first write when the ledger is empty. The plugin's lookup needs the time
range, which we have.

## 4. What I did not do

* **No UI or trigger wiring.** Natural hooks:
  * a toggle under Settings › Health sync (next to the import toggle), with its
    own `ensureWorkoutWriteAuthorized()` call so the user is never asked for
    import permissions;
  * calling `export()` after `SessionForm.onSaved` in gym mode
    (`lib/features/routines/widgets/gym_mode/session_page.dart`) and after
    editing a past session;
  * calling `remove()` from `WorkoutSessionRepository.deleteLocalDrift`'s
    callers;
  * a catch-up pass at app start over finished sessions from the last N days,
    for the `retryLater` results and for sessions that arrived through
    PowerSync from the web UI.

  Each needs a riverpod provider for the exporter and l10n strings.
* **Sessions created on the server or web** arrive through sync. With the
  catch-up pass they would be exported from whichever phone has the toggle on.
  If two phones both have it on, each writes the same `clientRecordId`.
  Health Connect is per device, so that only duplicates if the devices share a
  Health Connect store, which they don't.
* **iOS / HealthKit.** The plugin supports it, but HealthKit needs an
  `NSHealthUpdateUsageDescription`, a HealthKit write entitlement review, and
  `health_manifest_test` coverage. `canWriteWorkouts` is Android-only for now.
* **No device test.** The cloud VM has no emulator or KVM. Unverified on a real
  device:
  * the permission dialog text;
  * how Health Connect and Fit display a titled strength session;
  * whether Google Play's Health Connect declaration form needs updating for
    the new write permission (very likely: the manifest declared only read
    permissions until now);
  * the equal-version insert behaviour.

## 5. Risks and open questions for an upstream proposal

1. **Play policy:** adding `WRITE_EXERCISE` changes the Health Connect
   declaration in Play Console, and Google reviews it. The privacy policy
   section `#health-data` (linked from `MainActivity.kt`) only describes the
   import.
2. **Product value vs. data loss:** with only interval + type + title, the value
   is "my gym time shows up in Health Connect / Fitbit / Samsung Health and
   counts towards activity minutes". Ask the maintainers whether that is worth a
   setting.
3. **Segments:** Health Connect's `ExerciseSegment` could carry a per-exercise
   `repetitions` count (segment types like `BENCH_PRESS`, `SQUAT`), but not
   weight. Supporting it means extending the plugin and mapping wger exercises
   to about 30 segment types. That is a separate, larger spike.
4. **Profile time zone:** wger has `ownerTimeZoneProvider` (a zone name). Using
   it for the offsets needs a tz database (the `timezone` package). The
   device-zone approach is fine for almost everyone.
5. **Import loop:** the measurement import reads `ACTIVE_ENERGY_BURNED`,
   `STEPS` and so on, not `WORKOUT`, so exported sessions are never re-imported.
   If workout *import* is ever added, it must skip records whose
   `dataOrigin == de.wger.flutter`.
6. **Plugin pin:** the export API exists only in the fork, not in carp
   `health`. Upstream already depends on the fork for the read side, so this
   adds no new dependency.

## Build

**APK: not built.** I ran `flutter build apk --debug --target-platform
android-arm64` twice, with Android SDK `platforms;android-37.0`,
`build-tools;37.0.0` and NDK `28.2.13676358` installed through the command-line
tools. Both runs failed while Gradle was still configuring: Maven Central
(`repo.maven.apache.org`) answered HTTP **429 Too Many Requests** for Kotlin
Gradle plugin and gRPC POMs. The second run used `org.gradle.workers.max=2`.
No Dart or Kotlin compile step was reached.

The plugin's Kotlin is unchanged, and wger already builds it in CI, so the only
new Android input is one `<uses-permission>` line. The build's main risk is low
but untested. To check: run `flutter build apk --debug` locally or in this
fork's CI, or retry here later or with a Maven mirror.

## Environment notes (for HOW-TO-RUN)

The session's environment didn't match the brief:

* there was no `/opt/flutter`, no JDK 17 and `ANDROID_HOME` was unset;
* the `dart` MCP server failed to start (no `dart` on PATH);
* every git push got a 403 from GitHub (the app has no access to this repo for
  the org).

Flutter 3.47.7 was installed from `storage.googleapis.com` into
`/home/user/sdk/flutter`. `dl.google.com` and `storage.googleapis.com` were
reachable through the proxy.
