
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart'
    hide BleStatus;

import '../config.dart';
import '../services/bluetooth_service.dart';
import '../services/study_progress.dart';

/// Wearable sync screen (Day 1 and Day 15 only).
/// Recording continues in BluetoothService.instance while the user
/// navigates to other screens.
class SyncPage extends StatefulWidget {
  final String uid;
  final int day;
  final StudyProgress progress;

  const SyncPage({
    super.key,
    required this.uid,
    required this.day,
    required this.progress,
  });

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final BluetoothService _ble = BluetoothService.instance;

  bool _demo = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();

    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _ble.isActive) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _start({DiscoveredDevice? device}) async {
    await widget.progress.ensureStarted();

    await _ble.startSession(
      uid: widget.uid,
      day: widget.day,
      device: device,
      demo: _demo,
    );
  }

  Future<void> _confirmEnd() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End recording?'),
        content: Text(
          '${_ble.readingCount.value} readings have been saved so far.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep recording'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End & save'),
          ),
        ],
      ),
    );

    if (ok == true && mounted) {
      await _ble.endSession();
    }
  }

  String _elapsed() {
    final start = _ble.sessionStart;

    if (start == null) {
      return '00:00 / ${StudyConfig.wearableMaxMinutes}:00';
    }

    final elapsed = DateTime.now().difference(start);
    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');

    return '$minutes:$seconds / ${StudyConfig.wearableMaxMinutes}:00';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Day ${widget.day} Â· Wearable sync'),
      ),
      body: ValueListenableBuilder<BleStatus>(
        valueListenable: _ble.status,
        builder: (context, status, _) {
          final active = _ble.isActive;
          final finished = status == BleStatus.completed ||
              status == BleStatus.interrupted;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _statusCard(status),
              const SizedBox(height: 12),
              if (active) _liveSection(),
              if (finished) _finishedSection(status),
              if (!active && !finished) _setupSection(status),
            ],
          );
        },
      ),
    );
  }

  Widget _statusCard(BleStatus status) {
    final icon = status == BleStatus.streaming
        ? Icons.bluetooth_connected
        : status == BleStatus.error
            ? Icons.error_outline
            : Icons.bluetooth;

    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(status.name.toUpperCase()),
        subtitle: ValueListenableBuilder<String>(
          valueListenable: _ble.message,
          builder: (_, message, _) => Text(message),
        ),
      ),
    );
  }

  Widget _setupSection(BleStatus status) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Demo mode (simulated band)'),
          subtitle: const Text('For testing without hardware'),
          value: _demo,
          onChanged: (value) {
            setState(() => _demo = value);
          },
        ),
        const SizedBox(height: 8),
        if (_demo)
          FilledButton.icon(
            onPressed: () => _start(),
            icon: const Icon(Icons.play_arrow),
            label: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Start demo session'),
            ),
          )
        else ...[
          FilledButton.icon(
            onPressed:
                status == BleStatus.scanning ? null : _ble.startScan,
            icon: status == BleStatus.scanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.search),
            label: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                status == BleStatus.scanning
                    ? 'Scanningâ€¦'
                    : 'Scan for band',
              ),
            ),
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<List<DiscoveredDevice>>(
            valueListenable: _ble.devices,
            builder: (_, devices, _) {
              if (devices.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'No devices found yet. Scan for your wearable.',
                    textAlign: TextAlign.center,
                  ),
                );
              }

              return Column(
                children: [
                  for (final device in devices)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.watch),
                        title: Text(
                          device.name.isEmpty
                              ? 'Unnamed wearable'
                              : device.name,
                        ),
                        subtitle: Text('Signal ${device.rssi} dBm'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _start(device: device),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }

  Widget _liveSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Recording',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(_elapsed()),
                  ],
                ),
                const Divider(),
                ValueListenableBuilder<int>(
                  valueListenable: _ble.readingCount,
                  builder: (_, count, _) {
                    return Text('Readings saved: $count');
                  },
                ),
                ValueListenableBuilder<int>(
                  valueListenable: _ble.malformedCount,
                  builder: (_, count, _) {
                    if (count == 0) {
                      return const SizedBox.shrink();
                    }

                    return Text('Unreadable lines skipped: $count');
                  },
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder(
                  valueListenable: _ble.latest,
                  builder: (_, reading, _) {
                    if (reading == null) {
                      return const Text('Waiting for first readingâ€¦');
                    }

                    String formatValue(double? value, [int decimals = 2]) {
                      return value == null
                          ? 'Not available'
                          : value.toStringAsFixed(decimals);
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Heart rate: '
                          '${formatValue(reading.heartRateBpm, 0)} bpm',
                        ),
                        Text(
                          'HRV RMSSD: '
                          '${formatValue(reading.hrvRmssd, 1)} ms',
                        ),
                        Text(
                          'HRV SDNN: '
                          '${formatValue(reading.hrvSdnn, 1)} ms',
                        ),
                        Text(
                          'GSR: '
                          '${formatValue(reading.skinConductanceUs)} ÂµS',
                        ),
                        Text(
                          'Motion: '
                          '${formatValue(reading.imuAccelerationG)} g',
                        ),
                        Text(
                          'Label: ${reading.label}'
                          '${reading.valid ? '' : ' (flagged invalid)'}',
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _confirmEnd,
          icon: const Icon(Icons.stop),
          label: const Padding(
            padding: EdgeInsets.all(12),
            child: Text('End session'),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back to dashboard (keeps recording)'),
        ),
      ],
    );
  }

  Widget _finishedSection(BleStatus status) {
    final success = status == BleStatus.completed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Icon(
                  success
                      ? Icons.check_circle
                      : Icons.warning_amber_rounded,
                  size: 56,
                  color: success ? Colors.green : Colors.orange,
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<int>(
                  valueListenable: _ble.readingCount,
                  builder: (_, count, _) {
                    return Text(
                      success
                          ? 'Session saved: $count readings.'
                          : 'Session interrupted: $count readings saved.',
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Done'),
          ),
        ),
        TextButton(
          onPressed: _ble.reset,
          child: const Text('Record another session'),
        ),
      ],
    );
  }
}

