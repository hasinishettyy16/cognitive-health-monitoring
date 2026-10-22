# Yoga App — setup (Windows / any OS)

## 1. Files
Copy the `lib/` folder from this package over your project's `lib/`
(replace your old `main.dart`). Keep your existing `lib/firebase_options.dart`.

lib/
  main.dart  config.dart  firebase_options.dart (yours)
  models/sensor_reading.dart
  services/firestore_service.dart  study_progress.dart  bluetooth_service.dart  export_service.dart
  views/auth_pages.dart  home_page.dart  sync_page.dart  breathing_page.dart  puzzle_page.dart

Optional: delete `test/widget_test.dart` (it references the old `MyApp`).

## 2. Packages (run in project folder)
flutter pub add cloud_firestore shared_preferences flutter_reactive_ble permission_handler
(firebase_core and firebase_auth should already be there.)

## 3. Android
android/app/build.gradle(.kts): set minSdk to 23.
android/app/src/main/AndroidManifest.xml, inside <manifest> (above <application>):

  <uses-permission android:name="android.permission.INTERNET"/>
  <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>
  <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>
  <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"/>
  <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
  <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30"/>
  <uses-feature android:name="android.hardware.bluetooth_le" android:required="false"/>

If the build complains about the manifest flag, add xmlns:tools to <manifest> as the error suggests.

## 4. Firebase console
- Build > Firestore Database > Create database.
- Rules tab: paste firestore.rules, Publish.
- Authentication > Sign-in method: Email/Password enabled.

## 5. Run
flutter clean
flutter pub get
flutter run

## 6. Test without hardware
Day 1 > Sync Wearable Data > turn on "Demo mode" > Start demo session (about 50 s).
To test Day 15 behaviour set `debugDayOverride = 15` in config.dart (set back to null after).
Before the real study set `testShortcuts = false` in config.dart.

## 7. BLE (later, when firmware is ready)
Edit BleConfig in config.dart: deviceNamePrefix, serviceUuid, dataCharacteristicUuid.
Firmware sends one text line per notification, ending with a newline, e.g.
  2026-09-07 09:00:00,73,2.47,1.03,Baseline
  (or with HRV: Timestamp,HR,RMSSD,SDNN,GSR,IMU,Label)
BLE does not work on the Android emulator; use a real phone.

## Firestore layout
users/{uid}
users/{uid}/sessions/{sessionId}
users/{uid}/sessions/{sessionId}/readings/{r0001..}
   Timestamp, Timestamp_Raw, HeartRate_BPM, HRV_RMSSD_ms, HRV_SDNN_ms,
   SkinConductance_uS, IMU_Acceleration_G, Cognitive_State_Label, valid, seq, day, sessionId
users/{uid}/gameScores/{dayNN_pre | dayNN_post}
users/{uid}/breathingLogs/{dayNN}
