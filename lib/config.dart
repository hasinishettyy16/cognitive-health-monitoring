/// All tunable study constants live here.
class StudyConfig {
  StudyConfig._();

  static const int totalDays = 15;

  /// Days on which wearable sync is allowed.
  static const List<int> wearableDays = [1, 15];

  // ---- Puzzle (1-back visual memory game) ----
  static const int puzzleTrials = 60; // 60 x 5 s = 5 minutes
  static const int trialMillis = 5000;
  static const int stimulusMillis = 1200;
  static const double targetProbability = 0.30;
  static const double passAccuracy = 0.70; // >= 70% => Passed

  // ---- Wearable session phases (minutes) ----
  static const int baselineMinutes = 5;
  static const int breathingMinutes = 15;
  static const int wearableMaxMinutes = 25;

  /// true  => Pre puzzle -> Breathing -> Post puzzle must be done in order.
  static const bool enforceFlow = true;

  /// true => shows "Finish now (testing)" in the breathing screen.
  /// Set to false before the real study.
  static const bool testShortcuts = true;

  /// Set to e.g. 15 to test Day-15 behaviour on a phone. null = real day.
  static const int? debugDayOverride = null;

  static const String defaultReminder = '18:00';
  static const List<String> genders = ['Female', 'Male', 'Other', 'Prefer not to say'];

  static String labelForElapsed(Duration d) {
    final m = d.inMinutes;
    if (m < baselineMinutes) return 'Baseline';
    if (m < baselineMinutes + breathingMinutes) return 'Session';
    return 'Post-Yoga';
  }
}

/// EDIT THESE when the ESP32 firmware is final.
class BleConfig {
  BleConfig._();

  /// Devices whose name starts with this are listed first when scanning.
  static const String deviceNamePrefix = 'YogaBand';

  /// Nordic-UART style defaults (placeholders until firmware is fixed).
  static const String serviceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  static const String dataCharacteristicUuid = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';

  static const int connectRetries = 3;
}
