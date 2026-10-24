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

import 'package:flutter_test/flutter_test.dart';
import 'package:health_bridge/health.dart';
import 'package:mockito/mockito.dart';
import 'package:wger/features/health/models/workout_export.dart';
import 'package:wger/features/health/providers/health_repository.dart';

import 'health_repository_test.mocks.dart';

HealthAuthorizationSnapshot workoutSnapshot(HealthAuthorizationState write) =>
    HealthAuthorizationSnapshot(
      available: true,
      types: [
        HealthTypeAuthorization(
          type: HealthDataType.WORKOUT,
          read: HealthAuthorizationState.notDetermined,
          write: write,
        ),
      ],
    );

void main() {
  late MockHealth health;
  late HealthRepository repository;

  final export = WorkoutExport(
    clientRecordId: '01890a5d-ac96-774b-bcce-b302099a8057',
    start: DateTime.utc(2026, 3, 10, 8),
    end: DateTime.utc(2026, 3, 10, 9),
    startZoneOffsetSeconds: 3600,
    endZoneOffsetSeconds: 3600,
    title: 'Leg day',
  );

  setUpAll(() {
    // Final classes with validating factories, mockito cannot make one up
    provideDummy(workoutSnapshot(HealthAuthorizationState.notDetermined));
    provideDummy(
      HealthWorkoutWriteResult(
        status: HealthWorkoutWriteStatus.unavailable,
        energyStatus: HealthEnergyWriteStatus.notExpected,
        retryable: false,
        submissionCertainty: HealthSubmissionCertainty.notSubmitted,
      ),
    );
    provideDummy(
      HealthWorkoutLookupResult(
        workout: HealthRecordLookup(status: HealthRecordLookupStatus.unavailable),
        energy: HealthRecordLookup(status: HealthRecordLookupStatus.notExpected),
        derivedStatus: HealthWorkoutLookupStatus.unavailable,
      ),
    );
  });

  setUp(() {
    health = MockHealth();
    repository = HealthRepository(health);
    when(health.configure()).thenAnswer((_) async {});
  });

  test('writes one workout without energy, as a manual phone entry', () async {
    final result = HealthWorkoutWriteResult(
      status: HealthWorkoutWriteStatus.written,
      workoutRecordId: 'hc-1',
      energyStatus: HealthEnergyWriteStatus.notExpected,
      retryable: false,
      submissionCertainty: HealthSubmissionCertainty.submitted,
    );
    when(
      health.writeWorkoutData(
        workoutClientRecordId: anyNamed('workoutClientRecordId'),
        energyClientRecordId: anyNamed('energyClientRecordId'),
        clientRecordVersion: anyNamed('clientRecordVersion'),
        activityType: anyNamed('activityType'),
        start: anyNamed('start'),
        end: anyNamed('end'),
        startZoneOffsetSeconds: anyNamed('startZoneOffsetSeconds'),
        endZoneOffsetSeconds: anyNamed('endZoneOffsetSeconds'),
        activeEnergyKcal: anyNamed('activeEnergyKcal'),
        title: anyNamed('title'),
        recordingProvenance: anyNamed('recordingProvenance'),
        recordingDevice: anyNamed('recordingDevice'),
      ),
    ).thenAnswer((_) async => result);

    expect(await repository.writeWorkout(export), same(result));

    verify(
      health.writeWorkoutData(
        workoutClientRecordId: export.clientRecordId,
        clientRecordVersion: 0,
        activityType: HealthWorkoutActivityType.STRENGTH_TRAINING,
        start: export.start,
        end: export.end,
        startZoneOffsetSeconds: 3600,
        endZoneOffsetSeconds: 3600,
        title: 'Leg day',
        recordingProvenance: HealthRecordingProvenance.manualEntry,
        recordingDevice: HealthRecordingDevice.phone,
      ),
    ).called(1);
  });

  test('looks the workout up under the same id and interval', () async {
    when(
      health.lookupWorkoutData(
        workoutClientRecordId: anyNamed('workoutClientRecordId'),
        energyClientRecordId: anyNamed('energyClientRecordId'),
        start: anyNamed('start'),
        end: anyNamed('end'),
      ),
    ).thenAnswer(
      (_) async => HealthWorkoutLookupResult(
        workout: HealthRecordLookup(status: HealthRecordLookupStatus.absent),
        energy: HealthRecordLookup(status: HealthRecordLookupStatus.notExpected),
        derivedStatus: HealthWorkoutLookupStatus.absent,
      ),
    );

    await repository.lookupWorkout(export);

    verify(
      health.lookupWorkoutData(
        workoutClientRecordId: export.clientRecordId,
        start: export.start,
        end: export.end,
      ),
    ).called(1);
  });

  group('workout write permission', () {
    test('is not requested when already granted', () async {
      when(
        health.getAuthorizationSnapshot(any),
      ).thenAnswer((_) async => workoutSnapshot(HealthAuthorizationState.authorized));

      expect(await repository.ensureWorkoutWriteAuthorized(), isTrue);
      verifyNever(health.requestAuthorization(any, permissions: anyNamed('permissions')));
    });

    test('is requested for writing only, and the snapshot decides', () async {
      final answers = [
        workoutSnapshot(HealthAuthorizationState.notDetermined),
        workoutSnapshot(HealthAuthorizationState.denied),
      ];
      when(health.getAuthorizationSnapshot(any)).thenAnswer((_) async => answers.removeAt(0));
      when(
        health.requestAuthorization(any, permissions: anyNamed('permissions')),
      ).thenAnswer((_) async => true);

      // The request "succeeds", but the user unticked the permission
      expect(await repository.ensureWorkoutWriteAuthorized(), isFalse);
      verify(
        health.requestAuthorization(
          [HealthDataType.WORKOUT],
          permissions: [HealthDataAccess.WRITE],
        ),
      ).called(1);
    });

    test('counts as missing when the snapshot fails', () async {
      when(health.getAuthorizationSnapshot(any)).thenThrow(Exception('no snapshot'));

      expect(await repository.isWorkoutWriteAuthorized(), isFalse);
    });
  });

  test('deletes by the client record id', () async {
    when(
      health.deleteByClientRecordId(
        dataTypeKey: anyNamed('dataTypeKey'),
        clientRecordId: anyNamed('clientRecordId'),
        recordId: anyNamed('recordId'),
      ),
    ).thenAnswer((_) async => true);

    expect(await repository.deleteWorkout(export.clientRecordId), isTrue);
    verify(
      health.deleteByClientRecordId(
        dataTypeKey: HealthDataType.WORKOUT,
        clientRecordId: export.clientRecordId,
      ),
    ).called(1);
  });
}
