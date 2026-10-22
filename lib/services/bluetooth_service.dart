import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config.dart';
import '../models/sensor_reading.dart';
import 'firestore_service.dart';

enum BleStatus { idle, scanning, connecting, streaming, reconnecting, completed, interrupted, error }

/// Singleton so a recording keeps running while the user moves between
/// the dashboard, breathing screen and puzzle.
class BluetoothService {
  BluetoothService._();
  static final BluetoothService instance = BluetoothService._();

  final FlutterReactiveBle _ble = FlutterReactiveBle();

  final ValueNotifier<BleStatus> status = ValueNotifier(BleStatus.idle);
  final ValueNotifier<String> message = ValueNotifier('Ready.');
  final ValueNotifier<List<DiscoveredDevice>> devices =
      ValueNotifier<List<DiscoveredDevice>>(const []);
  final ValueNotifier<SensorReading?> latest = ValueNotifier<SensorReading?>(null);
  final ValueNotifier<int> readingCount = ValueNotifier(0);
  final ValueNotifier<int> malformedCount = ValueNotifier(0);

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _dataSub;
  Timer? _scanTimer;
  Timer? _flushTimer;
  Timer? _demoTimer;
  Timer? _maxTimer;

  final Map<String, DiscoveredDevice> _found = {};
  String _buffer = '';
  String? _uid;
  String? _deviceId;
  bool _demo = false;
  bool _ending = false;
  bool _lossPending = false;
  int _seq = 0;
  int _retries = 0;

  String? sessionId;
  int activeDay = 1;
  DateTime? sessionStart;
  String deviceName = '';

  bool get isActive =>
      status.value == BleStatus.streaming ||
      status.value == BleStatus.connecting ||
      status.value == BleStatus.reconnecting;

  // ------------------------------------------------------------------
  // permissions + scanning
  // ------------------------------------------------------------------
  Future<bool> requestPermissions() async {
    final r = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final scan = r[Permission.bluetoothScan]?.isGranted ?? false;
    final conn = r[Permission.bluetoothConnect]?.isGranted ?? false;
    final loc = r[Permission.locationWhenInUse]?.isGranted ?? false;
    return (scan && conn) || loc;
  }

  Future<void> startScan() async {
    if (!await requestPermissions()) {
      status.value = BleStatus.error;
      message.value = 'Bluetooth permission denied. Allow it in phone settings.';
      return;
    }
    await stopScan();
    _found.clear();
    devices.value = const [];
    status.value = BleStatus.scanning;
    message.value = 'Scanning for devices...';
    _scanSub = _ble
        .scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency)
        .listen((d) {
      if (d.name.isEmpty) return;
      _found[d.id] = d;
      final list = _found.values.toList()
        ..sort((a, b) {
          final ap = a.name.startsWith(BleConfig.deviceNamePrefix) ? 0 : 1;
          final bp = b.name.startsWith(BleConfig.deviceNamePrefix) ? 0 : 1;
          if (ap != bp) return ap - bp;
          return b.rssi.compareTo(a.rssi);
        });
      devices.value = list;
    }, onError: (Object e) {
      status.value = BleStatus.error;
      message.value = 'Scan failed: $e';
    });
    _scanTimer = Timer(const Duration(seconds: 12), () async {
      await stopScan();
      if (status.value == BleStatus.scanning) {
        status.value = BleStatus.idle;
        message.value =
            devices.value.isEmpty ? 'No devices found. Try again.' : 'Select your band.';
      }
    });
  }

  Future<void> stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSub?.cancel();
    _scanSub = null;
  }

  // ------------------------------------------------------------------
  // session lifecycle
  // ------------------------------------------------------------------
  Future<void> startSession({
    required String uid,
    required int day,
    DiscoveredDevice? device,
    required bool demo,
  }) async {
    if (isActive) return;
    if (!demo && device == null) {
      message.value = 'Select a device first.';
      return;
    }
    await stopScan();
    _uid = uid;
    activeDay = day;
    _demo = demo;
    _ending = false;
    _lossPending = false;
    _seq = 0;
    _retries = 0;
    _buffer = '';
    readingCount.value = 0;
    malformedCount.value = 0;
    latest.value = null;
    sessionStart = DateTime.now();
    deviceName = demo ? 'Demo simulator' : device!.name;
    status.value = demo ? BleStatus.streaming : BleStatus.connecting;
    message.value = demo ? 'Demo mode running...' : 'Connecting to $deviceName...';

    sessionId = await FirestoreService.createSession(
      uid: uid,
      day: day,
      deviceName: deviceName,
      demo: demo,
    );

    _maxTimer?.cancel();
    _maxTimer = Timer(Duration(minutes: StudyConfig.wearableMaxMinutes), () {
      _finish(interrupted: false);
    });

    if (demo) {
      _startDemo();
    } else {
      _deviceId = device!.id;
      _connect();
    }
  }

  Future<void> endSession() => _finish(interrupted: false);

  /// Clears a finished session so a new one can be started.
  void reset() {
    if (isActive) return;
    status.value = BleStatus.idle;
    message.value = 'Ready.';
  }

  Future<void> _finish({required bool interrupted}) async {
    if (_ending || sessionId == null) return;
    if (!isActive) return;
    _ending = true;
    _maxTimer?.cancel();
    _flushTimer?.cancel();
    _demoTimer?.cancel();
    if (_buffer.trim().isNotEmpty) {
      final rest = _buffer;
      _buffer = '';
      _handleLine(rest);
    }
    await _dataSub?.cancel();
    _dataSub = null;
    await _connSub?.cancel();
    _connSub = null;

    final uid = _uid;
    final sid = sessionId;
    if (uid != null && sid != null) {
      final st = interrupted ? 'interrupted' : (_seq > 0 ? 'completed' : 'empty');
      await FirestoreService.updateSession(
        uid: uid,
        sessionId: sid,
        data: {
          'status': st,
          'endedAt': Timestamp.now(),
          'readingCount': _seq,
        },
      );
    }
    status.value = interrupted ? BleStatus.interrupted : BleStatus.completed;
    message.value = interrupted
        ? 'Connection lost. $_seq readings were saved.'
        : 'Session finished. $_seq readings saved.';
  }

  // ------------------------------------------------------------------
  // BLE connection
  // ------------------------------------------------------------------
  void _connect() {
    final id = _deviceId;
    if (id == null) return;
    _connSub?.cancel();
    status.value = _retries == 0 ? BleStatus.connecting : BleStatus.reconnecting;
    message.value = _retries == 0
        ? 'Connecting to $deviceName...'
        : 'Reconnecting (attempt $_retries of ${BleConfig.connectRetries})...';
    _connSub = _ble
        .connectToDevice(id: id, connectionTimeout: const Duration(seconds: 10))
        .listen((update) {
      switch (update.connectionState) {
        case DeviceConnectionState.connected:
          _onConnected(id);
          break;
        case DeviceConnectionState.disconnected:
          _onLinkLost();
          break;
        default:
          break;
      }
    }, onError: (Object e) {
      _onLinkLost();
    });
  }

  Future<void> _onConnected(String id) async {
    _retries = 0;
    _lossPending = false;
    status.value = BleStatus.streaming;
    message.value = 'Connected. Receiving data...';
    try {
      await _ble.requestMtu(deviceId: id, mtu: 185);
    } catch (_) {}
    await _dataSub?.cancel();
    final ch = QualifiedCharacteristic(
      serviceId: Uuid.parse(BleConfig.serviceUuid),
      characteristicId: Uuid.parse(BleConfig.dataCharacteristicUuid),
      deviceId: id,
    );
    _dataSub = _ble.subscribeToCharacteristic(ch).listen(
      _onBytes,
      onError: (Object e) {
        message.value = 'Data stream error: $e';
      },
    );
  }

  void _onLinkLost() {
    if (_ending || _demo || !isActive || _lossPending) return;
    _lossPending = true;
    _dataSub?.cancel();
    _dataSub = null;
    if (_retries >= BleConfig.connectRetries) {
      _lossPending = false;
      _finish(interrupted: true);
      return;
    }
    _retries++;
    status.value = BleStatus.reconnecting;
    message.value = 'Connection lost. Retrying ($_retries of ${BleConfig.connectRetries})...';
    Future.delayed(const Duration(seconds: 2), () {
      _lossPending = false;
      if (_ending || !isActive) return;
      _connect();
    });
  }

  // ------------------------------------------------------------------
  // streaming parser: bytes -> lines -> SensorReading -> Firestore
  // ------------------------------------------------------------------
  void _onBytes(List<int> data) {
    _buffer += utf8.decode(data, allowMalformed: true);
    int idx = _buffer.indexOf('\n');
    while (idx != -1) {
      final line = _buffer.substring(0, idx);
      _buffer = _buffer.substring(idx + 1);
      _handleLine(line);
      idx = _buffer.indexOf('\n');
    }
    _flushTimer?.cancel();
    if (_buffer.trim().isNotEmpty) {
      // Firmware that never sends '\n': treat a quiet buffer as one full line.
      _flushTimer = Timer(const Duration(milliseconds: 1500), () {
        final rest = _buffer;
        _buffer = '';
        _handleLine(rest);
      });
    }
  }

  String _fallbackLabel() =>
      StudyConfig.labelForElapsed(DateTime.now().difference(sessionStart ?? DateTime.now()));

  void _handleLine(String raw) {
    final line = raw.replaceAll('\r', '').trim();
    if (line.isEmpty) return;
    final r = SensorReading.tryParse(line, fallbackLabel: _fallbackLabel);
    if (r == null) {
      final l = line.toLowerCase();
      if (!l.startsWith('timestamp') && !l.startsWith('heartrate')) {
        malformedCount.value = malformedCount.value + 1;
      }
      return;
    }
    final uid = _uid;
    final sid = sessionId;
    if (uid == null || sid == null) return;
    _seq++;
    FirestoreService.addReading(
      uid: uid,
      sessionId: sid,
      seq: _seq,
      data: r.toMap(seq: _seq, day: activeDay, sessionId: sid),
    );
    latest.value = r;
    readingCount.value = _seq;
  }

  // ------------------------------------------------------------------
  // demo mode: simulated 1-row-per-minute stream, sped up to 1 row / 2 s
  // ------------------------------------------------------------------
  void _startDemo() {
    final rnd = Random();
    final base = DateTime.now();
    int i = 0;
    _demoTimer = Timer.periodic(const Duration(seconds: 2), (t) {
      final ts = SensorReading.formatTimestamp(base.add(Duration(minutes: i)));
      String label;
      double hr;
      double gsr;
      double imu;
      if (i < StudyConfig.baselineMinutes) {
        label = 'Baseline';
        hr = 70.0 + rnd.nextInt(7);
        gsr = 2.1 + rnd.nextDouble() * 0.8;
        imu = 0.9 + rnd.nextDouble() * 0.2;
      } else if (i < StudyConfig.baselineMinutes + StudyConfig.breathingMinutes) {
        label = 'Session';
        hr = 62.0 + rnd.nextInt(8);
        gsr = 1.8 + rnd.nextDouble() * 0.6;
        imu = 0.85 + rnd.nextDouble() * 0.1;
      } else {
        label = 'Post-Yoga';
        hr = 64.0 + rnd.nextInt(6);
        gsr = 1.7 + rnd.nextDouble() * 0.5;
        imu = 0.9 + rnd.nextDouble() * 0.1;
      }
      final rmssd = 35 + rnd.nextDouble() * 20;
      final sdnn = 40 + rnd.nextDouble() * 25;
      _handleLine('$ts,${hr.toStringAsFixed(0)},${rmssd.toStringAsFixed(1)},'
          '${sdnn.toStringAsFixed(1)},${gsr.toStringAsFixed(2)},'
          '${imu.toStringAsFixed(2)},$label');
      i++;
      if (i >= StudyConfig.wearableMaxMinutes) {
        _finish(interrupted: false);
      }
    });
  }
}
