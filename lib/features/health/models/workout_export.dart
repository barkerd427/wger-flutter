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
import 'package:health_bridge/health.dart';
import 'package:wger/features/routines/models/session.dart';

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Why a session cannot be exported (yet), see [WorkoutExport.check].
enum WorkoutExportBlocker {
  /// Not persisted, so there is no stable id to export it under
  noId,

  /// Still running: Health Connect needs an end time
  notFinished,

  /// End before or at the start
  emptyInterval,

  /// Longer than any session the app itself creates, most likely a typo
  tooLong,

  /// Ends in the future
  inFuture,
}

/// One wger workout session as the platform's workout record.
///
/// Deliberately small: Health Connect gets the interval, the activity type and
/// a title. The sets and weights stay in wger, the platform's workout record
/// has no place for them (an `ExerciseSegment` carries a rep count, but neither
/// weight nor RiR, and the plugin writes no segments at all).
///
/// No active energy is attached: wger does not measure it, and an estimate
/// would land in the user's daily calorie totals as if it were measured.
class WorkoutExport {
  const WorkoutExport({
    required this.clientRecordId,
    required this.start,
    required this.end,
    required this.startZoneOffsetSeconds,
    required this.endZoneOffsetSeconds,
    required this.title,
    this.activityType = HealthWorkoutActivityType.STRENGTH_TRAINING,
  });

  /// The session's own UUID.
  ///
  /// Health Connect deduplicates on it: writing the same id (and version) a
  /// second time keeps one record, so a retry after an unclear outcome is
  /// safe. The session ids are client-minted UUIDs that never change, which
  /// is exactly what the platform wants here.
  final String clientRecordId;
  final DateTime start;
  final DateTime end;
  final int startZoneOffsetSeconds;
  final int endZoneOffsetSeconds;
  final String title;
  final HealthWorkoutActivityType activityType;

  /// The frozen envelope, persisted before the first write: a retry or the
  /// lookup after an unclear outcome has to send exactly these values again,
  /// even when the session was edited in the meantime
  Map<String, Object> toJson() => {
    'clientRecordId': clientRecordId,
    'start': start.toUtc().toIso8601String(),
    'end': end.toUtc().toIso8601String(),
    'startZoneOffsetSeconds': startZoneOffsetSeconds,
    'endZoneOffsetSeconds': endZoneOffsetSeconds,
    'title': title,
    'activityType': activityType.name,
  };

  factory WorkoutExport.fromJson(Map<String, Object?> json) => WorkoutExport(
    clientRecordId: json['clientRecordId']! as String,
    start: DateTime.parse(json['start']! as String),
    end: DateTime.parse(json['end']! as String),
    startZoneOffsetSeconds: json['startZoneOffsetSeconds']! as int,
    endZoneOffsetSeconds: json['endZoneOffsetSeconds']! as int,
    title: json['title']! as String,
    activityType: HealthWorkoutActivityType.values.byName(json['activityType']! as String),
  );

  /// Whether this envelope still describes [session]: same interval. The
  /// title is left out on purpose, renaming a routine day is no reason to
  /// rewrite the platform record.
  bool matches(WorkoutSession session) =>
      session.id == clientRecordId &&
      session.datetimeStart.isAtSameMomentAs(start) &&
      (session.datetimeEnd?.isAtSameMomentAs(end) ?? false);

  /// What keeps [session] from being exported, null when nothing does.
  static WorkoutExportBlocker? check(WorkoutSession session) {
    final id = session.id;
    if (id == null || !_uuidPattern.hasMatch(id)) {
      return WorkoutExportBlocker.noId;
    }
    final end = session.datetimeEnd;
    if (end == null) {
      return WorkoutExportBlocker.notFinished;
    }
    if (!end.isAfter(session.datetimeStart)) {
      return WorkoutExportBlocker.emptyInterval;
    }
    if (end.difference(session.datetimeStart) > sessionMaxDuration) {
      return WorkoutExportBlocker.tooLong;
    }
    if (end.isAfter(clock.now())) {
      return WorkoutExportBlocker.inFuture;
    }
    return null;
  }

  /// The export of [session], or null when [check] finds a blocker.
  ///
  /// [title] is what the platform shows for the workout, usually the routine
  /// day's name; blank falls back to [fallbackTitle].
  static WorkoutExport? fromSession(
    WorkoutSession session, {
    String? title,
    required String fallbackTitle,
  }) {
    if (check(session) != null) {
      return null;
    }
    final start = session.datetimeStart;
    final end = session.datetimeEnd!;
    final trimmed = title?.trim() ?? '';

    return WorkoutExport(
      clientRecordId: session.id!,
      start: start,
      end: end,
      // The device zone at each instant, which is right across a DST change.
      // The owner's profile zone would be better for a session logged while
      // travelling, but turning a zone name into an offset needs a tz database
      startZoneOffsetSeconds: start.toLocal().timeZoneOffset.inSeconds,
      endZoneOffsetSeconds: end.toLocal().timeZoneOffset.inSeconds,
      title: trimmed.isEmpty ? fallbackTitle : trimmed,
    );
  }
}
