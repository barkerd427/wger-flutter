/*
 * This file is part of wger Workout Manager <https://github.com/wger-project>.
 * Copyright (c) 2026 - 2026 wger Team
 *
 * wger Workout Manager is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_bridge/health.dart';
import 'package:wger/features/health/models/workout_export.dart';
import 'package:wger/features/health/providers/health_repository.dart';
import 'package:wger/features/health/providers/health_workout_exporter.dart';
import 'package:wger/features/routines/models/session.dart';

const sessionId = '01890a5d-ac96-774b-bcce-b302099a8057';

HealthWorkoutWriteResult written() => HealthWorkoutWriteResult(
  status: HealthWorkoutWriteStatus.written,
  workoutRecordId: 'hc-1',
  energyStatus: HealthEnergyWriteStatus.notExpected,
  retryable: false,
  submissionCertainty: HealthSubmissionCertainty.submitted,
);

HealthWorkoutWriteResult notSubmitted(HealthWorkoutWriteStatus status) => HealthWorkoutWriteResult(
  status: status,
  energyStatus: HealthEnergyWriteStatus.notExpected,
  retryable: status == HealthWorkoutWriteStatus.transientFailure,
  submissionCertainty: HealthSubmissionCertainty.notSubmitted,
);

HealthWorkoutWriteResult unclear() => HealthWorkoutWriteResult(
  status: HealthWorkoutWriteStatus.verificationRequired,
  energyStatus: HealthEnergyWriteStatus.notExpected,
  retryable: true,
  submissionCertainty: HealthSubmissionCertainty.mayHaveSubmitted,
);

HealthWorkoutLookupResult lookup(HealthRecordLookupStatus workout) => HealthWorkoutLookupResult(
  workout: HealthRecordLookup(
    status: workout,
    recordId: workout == HealthRecordLookupStatus.present ? 'hc-1' : null,
  ),
  energy: HealthRecordLookup(status: HealthRecordLookupStatus.notExpected),
  derivedStatus: switch (workout) {
    HealthRecordLookupStatus.present => HealthWorkoutLookupStatus.workoutOnly,
    HealthRecordLookupStatus.absent => HealthWorkoutLookupStatus.absent,
    _ => HealthWorkoutLookupStatus.unavailable,
  },
);

/// Records what the exporter sends, answers from queues set up per test.
class FakeHealthRepository extends Fake implements HealthRepository {
  bool supported = true;
  final writeResults = <Object>[];
  final lookupResults = <Object>[];
  bool deleteSucceeds = true;

  final writes = <WorkoutExport>[];
  final lookups = <WorkoutExport>[];
  final deletes = <String>[];

  @override
  bool get canWriteWorkouts => supported;

  @override
  Future<HealthWorkoutWriteResult> writeWorkout(WorkoutExport export) async {
    writes.add(export);
    final next = writeResults.removeAt(0);
    if (next is HealthWorkoutWriteResult) {
      return next;
    }
    throw next;
  }

  @override
  Future<HealthWorkoutLookupResult> lookupWorkout(WorkoutExport export) async {
    lookups.add(export);
    final next = lookupResults.removeAt(0);
    if (next is HealthWorkoutLookupResult) {
      return next;
    }
    throw next;
  }

  @override
  Future<bool> deleteWorkout(String clientRecordId) async {
    deletes.add(clientRecordId);
    return deleteSucceeds;
  }
}

void main() {
  final now = DateTime(2026, 3, 10, 12);
  final finished = WorkoutSession(
    id: sessionId,
    routineId: 1,
    datetimeStart: DateTime(2026, 3, 10, 9),
    datetimeEnd: DateTime(2026, 3, 10, 10),
  );

  late FakeHealthRepository health;
  late InMemoryWorkoutExportLedger ledger;
  late HealthWorkoutExporter exporter;

  setUp(() {
    health = FakeHealthRepository();
    ledger = InMemoryWorkoutExportLedger();
    exporter = HealthWorkoutExporter(health, ledger);
  });

  Future<WorkoutExportOutcome> export([WorkoutSession? session]) => withClock(
    Clock.fixed(now),
    () => exporter.export(session ?? finished, title: 'Leg day', fallbackTitle: 'Workout'),
  );

  test('writes a finished session once and remembers it', () async {
    health.writeResults.add(written());

    expect(await export(), WorkoutExportOutcome.exported);
    expect(await export(), WorkoutExportOutcome.upToDate);

    expect(health.writes, hasLength(1));
    expect(health.writes.single.clientRecordId, sessionId);
    expect(health.writes.single.title, 'Leg day');
    expect(ledger.entries[sessionId]!.confirmed, isTrue);
  });

  test('sends nothing for a session that is still running', () async {
    expect(
      await export(finished.copyWith(datetimeEnd: null)),
      WorkoutExportOutcome.notEligible,
    );
    expect(health.writes, isEmpty);
    expect(ledger.entries, isEmpty);
  });

  test('sends nothing where the platform cannot take workouts', () async {
    health.supported = false;

    expect(await export(), WorkoutExportOutcome.unsupported);
    expect(health.writes, isEmpty);
  });

  test('forgets the envelope when the permission is missing', () async {
    health.writeResults.add(notSubmitted(HealthWorkoutWriteStatus.blockedWorkoutPermission));

    expect(await export(), WorkoutExportOutcome.permissionMissing);
    expect(ledger.entries, isEmpty);
  });

  test('retries a transient failure with a fresh write', () async {
    health.writeResults
      ..add(notSubmitted(HealthWorkoutWriteStatus.transientFailure))
      ..add(written());

    expect(await export(), WorkoutExportOutcome.retryLater);
    expect(ledger.entries, isEmpty);
    expect(await export(), WorkoutExportOutcome.exported);
    expect(health.lookups, isEmpty, reason: 'nothing was submitted, so nothing to look up');
  });

  test('a rejected record counts as failed', () async {
    health.writeResults.add(notSubmitted(HealthWorkoutWriteStatus.invalidInput));

    expect(await export(), WorkoutExportOutcome.failed);
    expect(ledger.entries, isEmpty);
  });

  group('an unclear write', () {
    test('is confirmed by the lookup that finds it', () async {
      health.writeResults.add(unclear());
      health.lookupResults.add(lookup(HealthRecordLookupStatus.present));

      expect(await export(), WorkoutExportOutcome.exported);
      expect(ledger.entries[sessionId]!.confirmed, isTrue);
      expect(health.writes, hasLength(1));
    });

    test('is written again only after a lookup proved it absent', () async {
      health.writeResults
        ..add(unclear())
        ..add(written());
      health.lookupResults.add(lookup(HealthRecordLookupStatus.absent));

      expect(await export(), WorkoutExportOutcome.retryLater);
      expect(await export(), WorkoutExportOutcome.exported);
      expect(health.writes, hasLength(2));
    });

    test('blocks every write while the lookup cannot tell', () async {
      health.writeResults.add(unclear());
      health.lookupResults
        ..add(lookup(HealthRecordLookupStatus.unavailable))
        ..add(lookup(HealthRecordLookupStatus.unavailable));

      expect(await export(), WorkoutExportOutcome.retryLater);
      expect(await export(), WorkoutExportOutcome.retryLater);

      expect(health.writes, hasLength(1), reason: 'a second write could duplicate the first');
      expect(ledger.entries[sessionId]!.confirmed, isFalse);
    });

    test('a thrown write is looked up before the next one', () async {
      health.writeResults
        ..add(PlatformException(code: 'boom'))
        ..add(written());
      health.lookupResults.add(lookup(HealthRecordLookupStatus.absent));

      expect(await export(), WorkoutExportOutcome.retryLater);
      expect(ledger.entries[sessionId]!.confirmed, isFalse);
      expect(await export(), WorkoutExportOutcome.exported);
      expect(health.lookups, hasLength(1));
    });

    test('the retry uses the frozen envelope, not the edited session', () async {
      health.writeResults.add(unclear());
      health.lookupResults.add(lookup(HealthRecordLookupStatus.unavailable));
      await export();

      health.lookupResults.add(lookup(HealthRecordLookupStatus.unavailable));
      await export(finished.copyWith(datetimeEnd: DateTime(2026, 3, 10, 10, 30)));

      expect(health.lookups.last.end, finished.datetimeEnd);
    });
  });

  group('an edited session', () {
    final edited = finished.copyWith(datetimeEnd: DateTime(2026, 3, 10, 10, 30));

    test('replaces the earlier record', () async {
      health.writeResults
        ..add(written())
        ..add(written());

      await export();
      expect(await export(edited), WorkoutExportOutcome.exported);

      expect(health.deletes, [sessionId]);
      expect(health.writes.last.end, edited.datetimeEnd);
      expect(ledger.entries[sessionId]!.export.matches(edited), isTrue);
    });

    test('keeps the earlier record when deleting it failed', () async {
      health.writeResults.add(written());
      await export();
      health.deleteSucceeds = false;

      expect(await export(edited), WorkoutExportOutcome.retryLater);
      expect(health.writes, hasLength(1));
      expect(ledger.entries[sessionId]!.export.matches(finished), isTrue);
    });
  });

  test('removing a deleted session deletes its record', () async {
    health.writeResults.add(written());
    await export();

    await exporter.remove(sessionId);

    expect(health.deletes, [sessionId]);
    expect(ledger.entries, isEmpty);
  });

  test('removing a session that was never exported touches nothing', () async {
    await exporter.remove(sessionId);
    expect(health.deletes, isEmpty);
  });
}
