import 'package:cloud_firestore/cloud_firestore.dart';

/// One row of the wearable stream.
///
/// Accepted line formats (comma separated, optional leading timestamp):
///  5 cols: Timestamp,HeartRate_BPM,SkinConductance_uS,IMU_Acceleration_G,Label   (sample CSV)
///  7 cols: Timestamp,HeartRate_BPM,HRV_RMSSD_ms,HRV_SDNN_ms,SkinConductance_uS,IMU_Acceleration_G,Label
///  4 / 6 cols: same as above without Timestamp (phone time is used)
/// The trailing label is optional; the app assigns one from elapsed time.
class SensorReading {
  final DateTime timestamp;
  final String timestampRaw;
  final double heartRateBpm;
  final double? hrvRmssd;
  final double? hrvSdnn;
  final double skinConductanceUs;
  final double imuAccelerationG;
  final String label;

  const SensorReading({
    required this.timestamp,
    required this.timestampRaw,
    required this.heartRateBpm,
    required this.hrvRmssd,
    required this.hrvSdnn,
    required this.skinConductanceUs,
    required this.imuAccelerationG,
    required this.label,
  });

  bool get valid =>
      heartRateBpm >= 30 &&
      heartRateBpm <= 220 &&
      skinConductanceUs > 0 &&
      skinConductanceUs <= 100 &&
      imuAccelerationG >= 0 &&
      imuAccelerationG <= 16;

  static String formatTimestamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  static SensorReading? tryParse(
    String rawLine, {
    required String Function() fallbackLabel,
    DateTime? now,
  }) {
    final line = rawLine.trim();
    if (line.isEmpty) return null;

    final parts = line.split(',').map((e) => e.trim()).toList();
    if (parts.isEmpty) return null;

    final first = parts.first.toLowerCase();
    if (first.startsWith('timestamp') || first.startsWith('heartrate')) {
      return null; // header row
    }

    DateTime? ts;
    String tsRaw = '';
    int start = 0;
    if (parts.first.contains('-')) {
      final parsed = DateTime.tryParse(parts.first);
      if (parsed != null) {
        ts = parsed;
        tsRaw = parts.first;
        start = 1;
      }
    }

    String? label;
    int end = parts.length;
    if (end > start && double.tryParse(parts[end - 1]) == null) {
      label = parts[end - 1];
      end--;
    }

    final nums = <double>[];
    for (int i = start; i < end; i++) {
      final v = double.tryParse(parts[i]);
      if (v == null) return null;
      nums.add(v);
    }

    double hr = 0;
    double gsr = 0;
    double imu = 0;
    double? rmssd;
    double? sdnn;
    if (nums.length == 3) {
      hr = nums[0];
      gsr = nums[1];
      imu = nums[2];
    } else if (nums.length == 5) {
      hr = nums[0];
      rmssd = nums[1];
      sdnn = nums[2];
      gsr = nums[3];
      imu = nums[4];
    } else {
      return null;
    }

    final DateTime when = ts ?? (now ?? DateTime.now());
    if (tsRaw.isEmpty) tsRaw = formatTimestamp(when);

    return SensorReading(
      timestamp: when,
      timestampRaw: tsRaw,
      heartRateBpm: hr,
      hrvRmssd: rmssd,
      hrvSdnn: sdnn,
      skinConductanceUs: gsr,
      imuAccelerationG: imu,
      label: (label != null && label.isNotEmpty) ? label : fallbackLabel(),
    );
  }

  Map<String, dynamic> toMap({
    required int seq,
    required int day,
    required String sessionId,
  }) {
    return {
      'Timestamp': Timestamp.fromDate(timestamp),
      'Timestamp_Raw': timestampRaw,
      'HeartRate_BPM': heartRateBpm,
      'HRV_RMSSD_ms': hrvRmssd,
      'HRV_SDNN_ms': hrvSdnn,
      'SkinConductance_uS': skinConductanceUs,
      'IMU_Acceleration_G': imuAccelerationG,
      'Cognitive_State_Label': label,
      'valid': valid,
      'seq': seq,
      'day': day,
      'sessionId': sessionId,
    };
  }
}
