import 'package:cloud_firestore/cloud_firestore.dart';

import 'firestore_service.dart';

/// Builds CSV text (headers follow the sample dataset's column names).
class ExportService {
  ExportService._();

  static String _esc(Object? v) {
    if (v == null) return '';
    final s = v.toString();
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  static String _row(List<Object?> cells) => '${cells.map(_esc).join(',')}\n';

  static Future<String> readingsCsv(String uid) async {
    final buf = StringBuffer(_row([
      'Day',
      'SessionId',
      'Timestamp',
      'HeartRate_BPM',
      'HRV_RMSSD_ms',
      'HRV_SDNN_ms',
      'SkinConductance_uS',
      'IMU_Acceleration_G',
      'Cognitive_State_Label',
      'Valid',
    ]));
    final ss = await FirestoreService.safeGet(
        FirestoreService.sessions(uid).orderBy('startedAt'));
    if (ss == null) return buf.toString();
    for (final s in ss.docs) {
      final rs = await FirestoreService.safeGet(
          FirestoreService.readings(uid, s.id).orderBy('seq'));
      if (rs == null) continue;
      for (final r in rs.docs) {
        final m = r.data();
        buf.write(_row([
          m['day'],
          s.id,
          m['Timestamp_Raw'],
          m['HeartRate_BPM'],
          m['HRV_RMSSD_ms'],
          m['HRV_SDNN_ms'],
          m['SkinConductance_uS'],
          m['IMU_Acceleration_G'],
          m['Cognitive_State_Label'],
          m['valid'],
        ]));
      }
    }
    return buf.toString();
  }

  static Future<String> scoresCsv(String uid) async {
    final buf = StringBuffer(_row([
      'Day',
      'Phase',
      'SavedAt',
      'Result',
      'Accuracy_pct',
      'Hits',
      'Misses',
      'FalseAlarms',
      'CorrectRejections',
      'AvgReactionMs',
      'Trials',
      'Alertness',
      'Fatigue',
      'Stress',
    ]));
    final snap = await FirestoreService.safeGet(FirestoreService.gameScores(uid).orderBy('day'));
    if (snap == null) return buf.toString();
    for (final d in snap.docs) {
      final m = d.data();
      final saved = m['savedAt'];
      buf.write(_row([
        m['day'],
        m['phase'],
        saved is Timestamp ? saved.toDate().toIso8601String() : '',
        m['result'],
        m['accuracyPct'],
        m['hits'],
        m['misses'],
        m['falseAlarms'],
        m['correctRejections'],
        m['avgReactionMs'],
        m['trials'],
        m['alertness'],
        m['fatigue'],
        m['stress'],
      ]));
    }
    return buf.toString();
  }
}
