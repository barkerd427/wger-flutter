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

import 'dart:convert';

import 'package:health_bridge/health.dart';
import 'package:logging/logging.dart';
import 'package:wger/core/shared_preferences.dart';
import 'package:wger/features/health/models/workout_export.dart';
import 'package:wger/features/health/providers/health_repository.dart';
import 'package:wger/features/routines/models/session.dart';

/// What [HealthWorkoutExporter.export] did with a session.
enum WorkoutExportOutcome {
  /// Written now
  exported,

  /// Was already on the platform with these times, nothing to do
  upToDate,

  /// Not finished or otherwise not exportable, see [WorkoutExportBlocker]
  notEligible,

  /// No platform to write to on this device
  unsupported,

  /// The user did not grant writing workouts
  permissionMissing,

  /// Nothing written for now, a later call may succeed
  retryLater,

  /// The platform refused the record or ended in a state we cannot resolve
  failed,
}

/// One session's export as remembered between runs.
class WorkoutExportEntry {
  const WorkoutExportEntry(this.export, {required this.confirmed});

  final WorkoutExport export;

  /// Whether the platform confirmed the record. False while a write may or
  /// may not have reached it, which only a lookup can settle
  final bool confirmed;

  Map<String, Object> toJson() => {'export': export.toJson(), 'confirmed': confirmed};

  factory WorkoutExportEntry.fromJson(Map<String, Object?> json) => WorkoutExportEntry(
    WorkoutExport.fromJson((json['export']! as Map).cast<String, Object?>()),
    confirmed: json['confirmed']! as bool,
  );
}

/// Where the exporter keeps its entries, keyed by session id.
abstract interface class WorkoutExportLedger {
  Future<WorkoutExportEntry?> get(String sessionId);

  Future<void> put(WorkoutExportEntry entry);

  Future<void> remove(String sessionId);
}

class InMemoryWorkoutExportLedger implements WorkoutExportLedger {
  final entries = <String, WorkoutExportEntry>{};

  @override
  Future<WorkoutExportEntry?> get(String sessionId) async => entries[sessionId];

  @override
  Future<void> put(WorkoutExportEntry entry) async => entries[entry.export.clientRecordId] = entry;

  @override
  Future<void> remove(String sessionId) async => entries.remove(sessionId);
}

/// Device-local on purpose: what this device wrote to its own health store is
/// no business of the server, and another device has a store of its own.
class PreferencesWorkoutExportLedger implements WorkoutExportLedger {
  static const _key = 'healthWorkoutExports';

  Future<Map<String, Object?>> _read() async {
    final stored = await PreferenceHelper.asyncPref.getString(_key);
    return stored == null ? {} : (jsonDecode(stored) as Map).cast<String, Object?>();
  }

  Future<void> _write(Map<String, Object?> value) =>
      PreferenceHelper.asyncPref.setString(_key, jsonEncode(value));

  @override
  Future<WorkoutExportEntry?> get(String sessionId) async {
    final raw = (await _read())[sessionId];
    return raw == null ? null : WorkoutExportEntry.fromJson((raw as Map).cast<String, Object?>());
  }

  @override
  Future<void> put(WorkoutExportEntry entry) async {
    final all = await _read();
    all[entry.export.clientRecordId] = entry.toJson();
    await _write(all);
  }

  @override
  Future<void> remove(String sessionId) async {
    final all = await _read();
    if (all.remove(sessionId) != null) {
      await _write(all);
    }
  }
}

/// Writes finished workout sessions to the health platform, once each.
///
/// Follows the plugin's export contract: the envelope is stored before the
/// write and reused verbatim until the platform confirmed it, and a write
/// whose outcome is unclear is looked up before anything is sent again. A
/// session edited after its export is deleted and written anew, since the
/// plugin only writes version 0 of a record.
class HealthWorkoutExporter {
  HealthWorkoutExporter(this._health, this._ledger);

  final HealthRepository _health;
  final WorkoutExportLedger _ledger;
  final _logger = Logger('HealthWorkoutExporter');

  /// Exports [session] unless it already is, see [WorkoutExportOutcome].
  ///
  /// Does not ask for permissions, see
  /// [HealthRepository.ensureWorkoutWriteAuthorized].
  Future<WorkoutExportOutcome> export(
    WorkoutSession session, {
    String? title,
    required String fallbackTitle,
  }) async {
    if (!_health.canWriteWorkouts) {
      return WorkoutExportOutcome.unsupported;
    }
    final blocker = WorkoutExport.check(session);
    if (blocker != null) {
      _logger.fine('Session ${session.id} is not exportable: ${blocker.name}');
      return WorkoutExportOutcome.notEligible;
    }

    var entry = await _ledger.get(session.id!);
    if (entry != null && !entry.confirmed) {
      entry = await _settle(entry);
      if (entry == null && await _ledger.get(session.id!) != null) {
        // Still unclear, and sending anything now could duplicate it
        return WorkoutExportOutcome.retryLater;
      }
    }

    if (entry != null) {
      if (entry.export.matches(session)) {
        return WorkoutExportOutcome.upToDate;
      }
      // Edited after the export: the old record has to go first, a second
      // write under the same id and version would not replace it
      if (!await _health.deleteWorkout(entry.export.clientRecordId)) {
        return WorkoutExportOutcome.retryLater;
      }
      await _ledger.remove(session.id!);
    }

    final export = WorkoutExport.fromSession(
      session,
      title: title,
      fallbackTitle: fallbackTitle,
    )!;
    await _ledger.put(WorkoutExportEntry(export, confirmed: false));

    final HealthWorkoutWriteResult result;
    try {
      result = await _health.writeWorkout(export);
    } catch (e) {
      // Whether it reached the platform is unknown, so the entry stays
      // unconfirmed and the next run looks it up first
      _logger.warning('Writing workout ${export.clientRecordId} failed: $e');
      return WorkoutExportOutcome.retryLater;
    }
    return _handleWrite(export, result);
  }

  /// Removes the platform record of a deleted session, if there is one.
  Future<void> remove(String sessionId) async {
    final entry = await _ledger.get(sessionId);
    if (entry == null || !_health.canWriteWorkouts) {
      return;
    }
    if (await _health.deleteWorkout(sessionId)) {
      await _ledger.remove(sessionId);
    }
  }

  Future<WorkoutExportOutcome> _handleWrite(
    WorkoutExport export,
    HealthWorkoutWriteResult result,
  ) async {
    final id = export.clientRecordId;
    switch (result.status) {
      case HealthWorkoutWriteStatus.written ||
          HealthWorkoutWriteStatus.alreadyPresent ||
          HealthWorkoutWriteStatus.writtenWithoutEnergy:
        await _ledger.put(WorkoutExportEntry(export, confirmed: true));
        return WorkoutExportOutcome.exported;

      // Nothing was submitted: forget the envelope, a later run builds a new
      // one from the then current session
      case HealthWorkoutWriteStatus.blockedWorkoutPermission:
        await _ledger.remove(id);
        return WorkoutExportOutcome.permissionMissing;
      case HealthWorkoutWriteStatus.transientFailure || HealthWorkoutWriteStatus.unavailable:
        await _ledger.remove(id);
        return WorkoutExportOutcome.retryLater;
      case HealthWorkoutWriteStatus.invalidInput:
        await _ledger.remove(id);
        _logger.warning('Health platform rejected workout $id as invalid');
        return WorkoutExportOutcome.failed;

      case HealthWorkoutWriteStatus.verificationRequired:
        final settled = await _settle(WorkoutExportEntry(export, confirmed: false));
        if (settled != null) {
          return WorkoutExportOutcome.exported;
        }
        return WorkoutExportOutcome.retryLater;

      // Energy without its workout. We never send energy, so this is another
      // app's doing or a plugin bug; left unconfirmed for a human to look at
      case HealthWorkoutWriteStatus.inconsistentNativeState:
        _logger.warning('Inconsistent health platform state for workout $id');
        return WorkoutExportOutcome.failed;
    }
  }

  /// Looks up an unconfirmed [entry]. Returns it confirmed when the platform
  /// has the record, null otherwise; the ledger keeps it only while the
  /// lookup could not tell.
  Future<WorkoutExportEntry?> _settle(WorkoutExportEntry entry) async {
    final id = entry.export.clientRecordId;
    final HealthWorkoutLookupResult lookup;
    try {
      lookup = await _health.lookupWorkout(entry.export);
    } catch (e) {
      _logger.warning('Looking up workout $id failed: $e');
      return null;
    }
    switch (lookup.derivedStatus) {
      case HealthWorkoutLookupStatus.present || HealthWorkoutLookupStatus.workoutOnly:
        final confirmed = WorkoutExportEntry(entry.export, confirmed: true);
        await _ledger.put(confirmed);
        return confirmed;
      case HealthWorkoutLookupStatus.absent:
        // The only answer that makes sending again safe
        await _ledger.remove(id);
        return null;
      case HealthWorkoutLookupStatus.unavailable || HealthWorkoutLookupStatus.inconsistent:
        return null;
    }
  }
}
