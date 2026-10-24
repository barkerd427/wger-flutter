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
import 'package:flutter_test/flutter_test.dart';
import 'package:health_bridge/health.dart';
import 'package:wger/features/health/models/workout_export.dart';
import 'package:wger/features/routines/models/session.dart';

const sessionId = '01890a5d-ac96-774b-bcce-b302099a8057';
final now = DateTime(2026, 3, 10, 12);

WorkoutSession session({
  String? id = sessionId,
  DateTime? start,
  DateTime? end,
}) => WorkoutSession(
  id: id,
  routineId: 1,
  datetimeStart: start ?? DateTime(2026, 3, 10, 9),
  datetimeEnd: end,
);

void main() {
  T atNow<T>(T Function() body) => withClock(Clock.fixed(now), body);

  group('check', () {
    test('a finished session has no blocker', () {
      expect(atNow(() => WorkoutExport.check(session(end: DateTime(2026, 3, 10, 10)))), isNull);
    });

    test('a session without a UUID cannot be exported', () {
      final end = DateTime(2026, 3, 10, 10);
      expect(
        atNow(() => WorkoutExport.check(session(id: null, end: end))),
        WorkoutExportBlocker.noId,
      );
      expect(
        atNow(() => WorkoutExport.check(session(id: 'local-1', end: end))),
        WorkoutExportBlocker.noId,
      );
    });

    test('a running session waits for its end', () {
      expect(atNow(() => WorkoutExport.check(session())), WorkoutExportBlocker.notFinished);
    });

    test('an empty or reversed interval is refused', () {
      final start = DateTime(2026, 3, 10, 9);
      expect(
        atNow(() => WorkoutExport.check(session(start: start, end: start))),
        WorkoutExportBlocker.emptyInterval,
      );
      expect(
        atNow(
          () => WorkoutExport.check(
            session(start: start, end: start.subtract(const Duration(minutes: 1))),
          ),
        ),
        WorkoutExportBlocker.emptyInterval,
      );
    });

    test('a session longer than the app ever creates is refused', () {
      final start = DateTime(2026, 3, 9, 9);
      expect(
        atNow(
          () => WorkoutExport.check(
            session(start: start, end: start.add(sessionMaxDuration + const Duration(minutes: 1))),
          ),
        ),
        WorkoutExportBlocker.tooLong,
      );
    });

    test('a session ending in the future is refused', () {
      expect(
        atNow(
          () => WorkoutExport.check(
            session(start: DateTime(2026, 3, 10, 11), end: DateTime(2026, 3, 10, 13)),
          ),
        ),
        WorkoutExportBlocker.inFuture,
      );
    });
  });

  group('fromSession', () {
    test('uses the session id and interval', () {
      final start = DateTime(2026, 3, 10, 9);
      final end = DateTime(2026, 3, 10, 10, 15);
      final export = atNow(
        () => WorkoutExport.fromSession(
          session(start: start, end: end),
          title: 'Push day',
          fallbackTitle: 'Workout',
        ),
      )!;

      expect(export.clientRecordId, sessionId);
      expect(export.start, start);
      expect(export.end, end);
      expect(export.title, 'Push day');
      expect(export.activityType, HealthWorkoutActivityType.STRENGTH_TRAINING);
      expect(export.startZoneOffsetSeconds, start.timeZoneOffset.inSeconds);
      expect(export.endZoneOffsetSeconds, end.timeZoneOffset.inSeconds);
    });

    test('falls back to the default title when none or a blank one is given', () {
      final s = session(end: DateTime(2026, 3, 10, 10));
      expect(atNow(() => WorkoutExport.fromSession(s, fallbackTitle: 'Workout'))!.title, 'Workout');
      expect(
        atNow(() => WorkoutExport.fromSession(s, title: '  ', fallbackTitle: 'Workout'))!.title,
        'Workout',
      );
    });

    test('is null for a session that cannot be exported', () {
      expect(atNow(() => WorkoutExport.fromSession(session(), fallbackTitle: 'Workout')), isNull);
    });
  });

  group('envelope', () {
    final s = session(end: DateTime(2026, 3, 10, 10));
    late WorkoutExport export;

    setUp(() => export = atNow(() => WorkoutExport.fromSession(s, fallbackTitle: 'Workout'))!);

    test('survives a JSON round trip', () {
      final back = WorkoutExport.fromJson(export.toJson());

      expect(back.clientRecordId, export.clientRecordId);
      expect(back.start.isAtSameMomentAs(export.start), isTrue);
      expect(back.end.isAtSameMomentAs(export.end), isTrue);
      expect(back.startZoneOffsetSeconds, export.startZoneOffsetSeconds);
      expect(back.endZoneOffsetSeconds, export.endZoneOffsetSeconds);
      expect(back.title, export.title);
      expect(back.activityType, export.activityType);
      expect(back.matches(s), isTrue);
    });

    test('matches only the session with the same interval', () {
      expect(export.matches(s), isTrue);
      expect(export.matches(s.copyWith(notes: 'changed')), isTrue);
      expect(export.matches(s.copyWith(datetimeEnd: DateTime(2026, 3, 10, 10, 5))), isFalse);
      expect(export.matches(s.copyWith(datetimeStart: DateTime(2026, 3, 10, 8))), isFalse);
      expect(export.matches(s.copyWith(datetimeEnd: null)), isFalse);
    });
  });
}
