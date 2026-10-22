import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../services/bluetooth_service.dart';
import '../services/export_service.dart';
import '../services/study_progress.dart';
import 'breathing_page.dart';
import 'cri_dashboard_page.dart';
import 'puzzle_page.dart';
import 'sync_page.dart';

class HomePage extends StatefulWidget {
  final User user;
  const HomePage({super.key, required this.user});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StudyProgress? _progress;
  final BluetoothService _ble = BluetoothService.instance;
  String? _lastMarkedSession;

  String get _uid => widget.user.uid;

  @override
  void initState() {
    super.initState();
    _ble.status.addListener(_onBleStatus);
    _init();
  }

  @override
  void dispose() {
    _ble.status.removeListener(_onBleStatus);
    super.dispose();
  }

  Future<void> _init() async {
    final p = await StudyProgress.load(_uid);
    if (!mounted) return;
    setState(() => _progress = p);
    await p.syncFromCloud();
    if (mounted) setState(() {});
  }

  /// When a wearable recording completes, mark the sync step for that day.
  Future<void> _onBleStatus() async {
    final p = _progress;
    final sid = _ble.sessionId;
    if (p == null || sid == null) return;
    if (_ble.status.value == BleStatus.completed &&
        _ble.readingCount.value > 0 &&
        _lastMarkedSession != sid) {
      _lastMarkedSession = sid;
      await p.markDone(_ble.activeDay, 'sync');
      if (mounted) setState(() {});
    }
  }

  // ---------------- navigation ----------------

  Future<void> _go(Widget page) async {
    await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => page));
    if (mounted) setState(() {});
  }

  void _openPuzzle(String phase) {
    final p = _progress!;
    _go(PuzzlePage(uid: _uid, day: p.currentDay, phase: phase, progress: p));
  }

  void _openBreathing() {
    final p = _progress!;
    _go(BreathingPage(uid: _uid, day: p.currentDay, progress: p));
  }

  void _openSync() {
    final p = _progress!;
    _go(SyncPage(uid: _uid, day: p.currentDay, progress: p));
  }

  Future<void> _logout() async {
    if (_ble.isActive) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('End the wearable recording before logging out.')));
      return;
    }
    await FirebaseAuth.instance.signOut();
  }

  Future<void> _pickReminder() async {
    final p = _progress!;
    final parts = p.reminder.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 18,
      minute: int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0,
    );
    final t = await showTimePicker(context: context, initialTime: initial);
    if (t == null) return;
    await p.setReminder(
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
    if (mounted) setState(() {});
  }

  String _reminderLabel(StudyProgress p) {
    final parts = p.reminder.split(':');
    final t = TimeOfDay(
      hour: int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 18,
      minute: int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0,
    );
    return t.format(context);
  }

  Future<void> _export() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export data'),
        content: const Text('Copies CSV text to the clipboard. Paste it into a .csv file or sheet.'),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _copyCsv('Sensor readings', ExportService.readingsCsv(_uid));
            },
            child: const Text('Sensor readings'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _copyCsv('Puzzle scores', ExportService.scoresCsv(_uid));
            },
            child: const Text('Puzzle scores'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _copyCsv(String label, Future<String> csvFuture) async {
    final csv = await csvFuture;
    await Clipboard.setData(ClipboardData(text: csv));
    final rows = '\n'.allMatches(csv).length - 1;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label CSV copied ($rows rows).')));
  }

  // ---------------- build ----------------

  @override
  Widget build(BuildContext context) {
    final p = _progress;
    return Scaffold(
      appBar: AppBar(
        title: const Text('My 15-Day Journey'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'export') _export();
              if (v == 'reminder' && _progress != null) _pickReminder();
              if (v == 'logout') _logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('Export data')),
              PopupMenuItem(value: 'reminder', child: Text('Set daily reminder')),
              PopupMenuItem(value: 'logout', child: Text('Log out')),
            ],
          ),
        ],
      ),
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await p.syncFromCloud();
                if (mounted) setState(() {});
              },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: _content(p),
              ),
            ),
    );
  }

  List<Widget> _content(StudyProgress p) {
    final day = p.currentDay;
    final cs = Theme.of(context).colorScheme;
    final preDone = p.isDone(day, 'pre');
    final breathDone = p.isDone(day, 'breath');
    final postDone = p.isDone(day, 'post');
    final syncDay = StudyConfig.wearableDays.contains(day);
    final syncDone = p.isDone(day, 'sync');

    final breathEnabled = !breathDone && (!StudyConfig.enforceFlow || preDone);
    final postEnabled = !postDone && (!StudyConfig.enforceFlow || breathDone);

    final name = widget.user.displayName?.trim() ?? '';
    final hour = DateTime.now().hour;
    final greet = hour < 12 ? 'Good morning' : (hour < 17 ? 'Good afternoon' : 'Good evening');

    return [
      Text(name.isEmpty ? greet : '$greet, $name',
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      _RecordingBanner(onOpen: _openSync),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Day $day of ${StudyConfig.totalDays}',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: day / StudyConfig.totalDays, minHeight: 8),
              const SizedBox(height: 8),
              Text(p.started
                  ? 'Started on ${p.startDate!.toIso8601String().substring(0, 10)}'
                  : 'Day 1 begins when you start your first activity.'),
            ],
          ),
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.alarm),
          title: const Text('Daily session reminder'),
          subtitle: Text('Practice at the same time each day: ${_reminderLabel(p)}'),
          trailing: const Icon(Icons.edit, size: 18),
          onTap: _pickReminder,
        ),
      ),
      if (p.studyComplete)
        Card(
          color: cs.primaryContainer,
          child: const ListTile(
            leading: Icon(Icons.emoji_events),
            title: Text('Study complete!'),
            subtitle: Text('Day 15 recording and puzzles are done. Thank you.'),
          ),
        ),
      const SizedBox(height: 4),
      Text("Today's flow", style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      _step(
        icon: Icons.extension,
        label: 'Daily 5-Min Puzzle Â· Pre-session',
        sub: preDone ? 'Done Â· ${p.scoreText(day, 'pre') ?? ''}' : 'Do this first',
        onTap: preDone ? null : () => _openPuzzle('pre'),
      ),
      _step(
        icon: Icons.self_improvement,
        label: 'Guided Anulom-Vilom (${StudyConfig.breathingMinutes} min)',
        sub: breathDone
            ? 'Completed'
            : (breathEnabled ? 'Ready' : 'Complete the pre-session puzzle first'),
        onTap: breathEnabled ? _openBreathing : null,
      ),
      _step(
        icon: Icons.extension,
        label: 'Daily 5-Min Puzzle Â· Post-session',
        sub: postDone
            ? 'Done Â· ${p.scoreText(day, 'post') ?? ''}'
            : (postEnabled ? 'Ready' : 'Complete the breathing session first'),
        onTap: postEnabled ? () => _openPuzzle('post') : null,
      ),
      const SizedBox(height: 4),
      _step(
        icon: Icons.bluetooth,
        label: 'Sync Wearable Data',
        sub: !syncDay
            ? 'Available on Day 1 and Day 15'
            : (syncDone ? 'Recorded âœ“ (you can record again)' : 'Wear the band, then start recording'),
        onTap: syncDay ? _openSync : null,
      ),
      const SizedBox(height: 12),
      Card(
        child: ListTile(
          leading: const Icon(Icons.insights),
          title: const Text('CRI Dashboard & Metric Guide'),
          subtitle: const Text('Send synthetic test data or paste a session JSON to calculate CRI on the Python backend.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CriDashboardPage()),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text('Your 15 days', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [for (int d = 1; d <= StudyConfig.totalDays; d++) _dayChip(d, p.statusOf(d))],
      ),
      const SizedBox(height: 8),
      const Text('Green = done Â· Orange = partly done Â· Red = missed Â· Teal = today',
          style: TextStyle(fontSize: 12)),
    ];
  }

  Widget _step({
    required IconData icon,
    required String label,
    required String sub,
    required VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: onTap,
            icon: Icon(icon),
            label: Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Text(label)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 3, left: 6),
            child: Text(sub, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _dayChip(int d, DayStatus s) {
    Color bg;
    Color fg = Colors.white;
    switch (s) {
      case DayStatus.done:
        bg = Colors.green;
        break;
      case DayStatus.partial:
        bg = Colors.orange;
        break;
      case DayStatus.missed:
        bg = Colors.red.shade400;
        break;
      case DayStatus.today:
        bg = Colors.teal;
        break;
      case DayStatus.upcoming:
        bg = Colors.grey.shade300;
        fg = Colors.black87;
        break;
    }
    return CircleAvatar(
      radius: 18,
      backgroundColor: bg,
      child: Text('$d', style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
    );
  }
}

/// Shown on the dashboard while a wearable recording is running.
class _RecordingBanner extends StatelessWidget {
  final VoidCallback onOpen;
  const _RecordingBanner({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final ble = BluetoothService.instance;
    return ValueListenableBuilder<BleStatus>(
      valueListenable: ble.status,
      builder: (context, st, _) {
        if (!ble.isActive) return const SizedBox.shrink();
        return Card(
          color: Colors.red.shade50,
          child: ListTile(
            leading: const Icon(Icons.fiber_manual_record, color: Colors.red),
            title: const Text('Wearable recording in progress'),
            subtitle: ValueListenableBuilder<int>(
              valueListenable: ble.readingCount,
              builder: (_, n, _) => Text('$n readings saved Â· tap to open'),
            ),
            onTap: onOpen,
          ),
        );
      },
    );
  }
}

