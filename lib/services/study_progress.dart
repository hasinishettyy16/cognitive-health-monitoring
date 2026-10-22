import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'firestore_service.dart';

enum DayStatus { done, partial, missed, today, upcoming }

/// Local (shared_preferences) progress tracker, keyed by Firebase uid.
/// Steps per day: 'pre', 'post', 'breath', 'sync'.
class StudyProgress {
  final String uid;
  final SharedPreferences _prefs;

  StudyProgress._(this.uid, this._prefs);

  static Future<StudyProgress> load(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return StudyProgress._(uid, prefs);
  }

  static DateTime _dateOnly(DateTime d) => DateTime.utc(d.year, d.month, d.day);

  static String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
  }

  String get _kStart => '${uid}_startDate';
  String _kFlag(int day, String step) => '${uid}_d${day}_$step';
  String _kScore(int day, String phase) => '${uid}_score_d${day}_$phase';
  String get _kReminder => '${uid}_reminder';

  // ---------------- day logic ----------------

  DateTime? get startDate {
    final s = _prefs.getString(_kStart);
    if (s == null) return null;
    final p = DateTime.tryParse(s);
    if (p == null) return null;
    return _dateOnly(p);
  }

  bool get started => startDate != null;

  int get currentDay {
    final override = StudyConfig.debugDayOverride;
    if (override != null) return override;
    final s = startDate;
    if (s == null) return 1;
    final days = _dateOnly(DateTime.now()).difference(s).inDays;
    final d = days + 1;
    if (d < 1) return 1;
    if (d > StudyConfig.totalDays) return StudyConfig.totalDays;
    return d;
  }

  /// Day 1 begins with the first real activity (sync / puzzle / breathing).
  Future<void> ensureStarted() async {
    if (startDate != null) return;
    final today = DateTime.now();
    await _prefs.setString(_kStart, _fmt(today));
    unawaited(FirestoreService.setStartDate(uid, today));
  }

  // ---------------- step flags ----------------

  bool isDone(int day, String step) => _prefs.getBool(_kFlag(day, step)) ?? false;

  Future<void> markDone(int day, String step) async {
    await ensureStarted();
    await _prefs.setBool(_kFlag(day, step), true);
  }

  String? scoreText(int day, String phase) => _prefs.getString(_kScore(day, phase));

  Future<void> setScoreText(int day, String phase, String text) =>
      _prefs.setString(_kScore(day, phase), text);

  bool get studyComplete =>
      isDone(StudyConfig.totalDays, 'sync') && isDone(StudyConfig.totalDays, 'post');

  DayStatus statusOf(int day) {
    final pre = isDone(day, 'pre');
    final post = isDone(day, 'post');
    final br = isDone(day, 'breath');
    if (pre && post) return DayStatus.done;
    final cur = currentDay;
    if (day == cur) return DayStatus.today;
    if (day > cur) return DayStatus.upcoming;
    return (pre || post || br) ? DayStatus.partial : DayStatus.missed;
  }

  // ---------------- reminder ----------------

  String get reminder => _prefs.getString(_kReminder) ?? StudyConfig.defaultReminder;

  Future<void> setReminder(String hhmm) => _prefs.setString(_kReminder, hhmm);

  // ---------------- cloud reconciliation ----------------

  /// Rebuilds local state from Firestore (reinstall / new phone safe).
  Future<void> syncFromCloud() async {
    try {
      final snap = await FirestoreService.userDoc(uid).get().timeout(const Duration(seconds: 8));
      final cloudKey = snap.data()?['startDateKey'] as String?;
      final local = _prefs.getString(_kStart);
      if (cloudKey != null) {
        if (local == null || cloudKey.compareTo(local) < 0) {
          await _prefs.setString(_kStart, cloudKey);
        }
      } else if (local != null) {
        final p = DateTime.tryParse(local);
        if (p != null) unawaited(FirestoreService.setStartDate(uid, p));
      }
    } catch (e) {
      debugPrint('syncFromCloud(user) failed: $e');
    }

    final scores = await FirestoreService.safeGet(FirestoreService.gameScores(uid));
    if (scores != null) {
      for (final d in scores.docs) {
        final m = d.data();
        final day = (m['day'] as num?)?.toInt();
        final phase = m['phase'] as String?;
        if (day == null || phase == null) continue;
        await markDone(day, phase);
        final acc = (m['accuracyPct'] as num?)?.toStringAsFixed(0) ?? '-';
        await setScoreText(day, phase, '${m['result'] ?? ''} $acc%');
      }
    }

    final logs = await FirestoreService.safeGet(FirestoreService.breathingLogs(uid));
    if (logs != null) {
      for (final d in logs.docs) {
        final day = (d.data()['day'] as num?)?.toInt();
        if (day != null) await markDone(day, 'breath');
      }
    }

    final sess = await FirestoreService.safeGet(
        FirestoreService.sessions(uid).where('status', isEqualTo: 'completed'));
    if (sess != null) {
      for (final d in sess.docs) {
        final day = (d.data()['day'] as num?)?.toInt();
        if (day != null) await markDone(day, 'sync');
      }
    }
  }
}
