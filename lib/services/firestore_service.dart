import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// confirmed = server acknowledged, queued = saved offline (will sync later),
/// failed = rejected (e.g. security rules) or error.
enum WriteStatus { confirmed, queued, failed }

/// FIRESTORE SCHEMA (flat sub-collections under the user)
///
/// users/{uid}                              profile + startDate
/// users/{uid}/sessions/{sessionId}         one wearable recording (Day 1 / Day 15)
/// users/{uid}/sessions/{sid}/readings/{r0001...}   one doc per CSV row:
///      Timestamp, Timestamp_Raw, HeartRate_BPM, HRV_RMSSD_ms, HRV_SDNN_ms,
///      SkinConductance_uS, IMU_Acceleration_G, Cognitive_State_Label,
///      valid, seq, day, sessionId
/// users/{uid}/gameScores/{dayNN_pre|dayNN_post}    puzzle result (one per phase/day)
/// users/{uid}/breathingLogs/{dayNN}                15-min guided session log
class FirestoreService {
  FirestoreService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static DocumentReference<Map<String, dynamic>> userDoc(String uid) =>
      _db.collection('users').doc(uid);

  static CollectionReference<Map<String, dynamic>> sessions(String uid) =>
      userDoc(uid).collection('sessions');

  static CollectionReference<Map<String, dynamic>> readings(
          String uid, String sessionId) =>
      sessions(uid).doc(sessionId).collection('readings');

  static CollectionReference<Map<String, dynamic>> gameScores(String uid) =>
      userDoc(uid).collection('gameScores');

  static CollectionReference<Map<String, dynamic>> breathingLogs(String uid) =>
      userDoc(uid).collection('breathingLogs');

  static String dayKey(int day) => 'day${day.toString().padLeft(2, '0')}';

  static Future<WriteStatus> _write(Future<void> write, {int seconds = 6}) async {
    try {
      await write.timeout(Duration(seconds: seconds));
      return WriteStatus.confirmed;
    } on TimeoutException {
      return WriteStatus.queued;
    } catch (e) {
      debugPrint('Firestore write error: $e');
      return WriteStatus.failed;
    }
  }

  static Future<QuerySnapshot<Map<String, dynamic>>?> safeGet(
      Query<Map<String, dynamic>> query) async {
    try {
      return await query.get().timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('Firestore read error: $e');
      return null;
    }
  }

  // ---------------- profile ----------------

  static Future<WriteStatus> createUserProfile(
      String uid, Map<String, dynamic> data) {
    return _write(
      userDoc(uid).set({
        ...data,
        'createdAt': Timestamp.now(),
      }, SetOptions(merge: true)),
    );
  }

  static Future<WriteStatus> setStartDate(String uid, DateTime date) {
    String two(int n) => n.toString().padLeft(2, '0');
    return _write(
      userDoc(uid).set({
        'startDate': Timestamp.fromDate(date),
        'startDateKey': '${date.year}-${two(date.month)}-${two(date.day)}',
      }, SetOptions(merge: true)),
    );
  }

  // ---------------- wearable sessions ----------------

  static Future<String> createSession({
    required String uid,
    required int day,
    required String deviceName,
    required bool demo,
  }) async {
    final ref = sessions(uid).doc();
    await _write(
      ref.set({
        'day': day,
        'deviceName': deviceName,
        'mode': demo ? 'demo' : 'wearable',
        'status': 'recording',
        'startedAt': Timestamp.now(),
        'readingCount': 0,
      }),
      seconds: 3,
    );
    return ref.id;
  }

  static Future<WriteStatus> updateSession({
    required String uid,
    required String sessionId,
    required Map<String, dynamic> data,
  }) {
    return _write(
      sessions(uid).doc(sessionId).set(data, SetOptions(merge: true)),
      seconds: 3,
    );
  }

  /// Fire-and-forget so the live stream is never blocked by the network.
  static void addReading({
    required String uid,
    required String sessionId,
    required int seq,
    required Map<String, dynamic> data,
  }) {
    final id = 'r${seq.toString().padLeft(4, '0')}';
    readings(uid, sessionId).doc(id).set(data).catchError((Object e) {
      debugPrint('Reading write error: $e');
    });
  }

  // ---------------- puzzle + breathing ----------------

  static Future<WriteStatus> saveGameScore({
    required String uid,
    required int day,
    required String phase,
    required Map<String, dynamic> data,
  }) {
    return _write(
      gameScores(uid).doc('${dayKey(day)}_$phase').set(data),
    );
  }

  static Future<WriteStatus> saveBreathingLog({
    required String uid,
    required int day,
    required int durationSeconds,
  }) {
    return _write(
      breathingLogs(uid).doc(dayKey(day)).set({
        'day': day,
        'durationSeconds': durationSeconds,
        'completedAt': Timestamp.now(),
      }),
    );
  }
}
