import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../services/firestore_service.dart';
import '../services/study_progress.dart';

enum _Stage { intro, playing, result }

/// 5-minute visual 1-back memory game.
/// A square lights up in a 3x3 grid every 5 s (60 trials).
/// Tap "SAME" if the lit square is in the same place as the previous one.
class PuzzlePage extends StatefulWidget {
  final String uid;
  final int day;
  final String phase; // 'pre' or 'post'
  final StudyProgress progress;

  const PuzzlePage({
    super.key,
    required this.uid,
    required this.day,
    required this.phase,
    required this.progress,
  });

  @override
  State<PuzzlePage> createState() => _PuzzlePageState();
}

class _PuzzlePageState extends State<PuzzlePage> {
  static const int _n = StudyConfig.puzzleTrials;
  static const int _totalMs = _n * StudyConfig.trialMillis;

  _Stage _stage = _Stage.intro;
  final Random _rnd = Random();
  List<int> _positions = <int>[];
  final List<bool> _pressed = List<bool>.filled(_n, false);
  final List<int> _rt = List<int>.filled(_n, -1);
  final Stopwatch _clock = Stopwatch();
  Timer? _ticker;

  int _trial = 0;
  bool _stimOn = false;
  int _remainingSec = _totalMs ~/ 1000;

  int _hits = 0;
  int _misses = 0;
  int _falseAlarms = 0;
  int _correctRejections = 0;
  double _accuracy = 0;
  double? _avgRt;
  bool _passed = false;

  double _alertness = 3;
  double _fatigue = 3;
  double _stress = 3;
  bool _saving = false;

  String get _title => widget.phase == 'pre' ? 'Pre-session puzzle' : 'Post-session puzzle';

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  List<int> _generate() {
    final p = <int>[_rnd.nextInt(9)];
    for (int i = 1; i < _n; i++) {
      if (_rnd.nextDouble() < StudyConfig.targetProbability) {
        p.add(p[i - 1]);
      } else {
        int v;
        do {
          v = _rnd.nextInt(9);
        } while (v == p[i - 1]);
        p.add(v);
      }
    }
    return p;
  }

  void _start() {
    _positions = _generate();
    for (int i = 0; i < _n; i++) {
      _pressed[i] = false;
      _rt[i] = -1;
    }
    _clock
      ..reset()
      ..start();
    setState(() {
      _stage = _Stage.playing;
      _trial = 0;
      _stimOn = true;
      _remainingSec = _totalMs ~/ 1000;
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) => _onTick());
  }

  void _onTick() {
    final e = _clock.elapsedMilliseconds;
    if (e >= _totalMs) {
      _finishGame();
      return;
    }
    final t = e ~/ StudyConfig.trialMillis;
    final on = (e % StudyConfig.trialMillis) < StudyConfig.stimulusMillis;
    final rem = ((_totalMs - e) / 1000).ceil();
    if (t != _trial || on != _stimOn || rem != _remainingSec) {
      setState(() {
        _trial = t;
        _stimOn = on;
        _remainingSec = rem;
      });
    }
  }

  void _onMatch() {
    if (_stage != _Stage.playing) return;
    final e = _clock.elapsedMilliseconds;
    final t = e ~/ StudyConfig.trialMillis;
    if (t >= _n || t == 0 || _pressed[t]) return;
    _pressed[t] = true;
    _rt[t] = e - t * StudyConfig.trialMillis;
    HapticFeedback.lightImpact();
    setState(() {});
  }

  void _finishGame() {
    _ticker?.cancel();
    _clock.stop();
    int hits = 0;
    int misses = 0;
    int fa = 0;
    int cr = 0;
    final rts = <int>[];
    for (int i = 1; i < _n; i++) {
      final isTarget = _positions[i] == _positions[i - 1];
      final pressed = _pressed[i];
      if (isTarget && pressed) {
        hits++;
        if (_rt[i] >= 0) rts.add(_rt[i]);
      } else if (isTarget && !pressed) {
        misses++;
      } else if (!isTarget && pressed) {
        fa++;
      } else {
        cr++;
      }
    }
    final scored = _n - 1;
    final acc = (hits + cr) / scored;
    setState(() {
      _hits = hits;
      _misses = misses;
      _falseAlarms = fa;
      _correctRejections = cr;
      _accuracy = acc;
      _avgRt = rts.isEmpty ? null : rts.reduce((a, b) => a + b) / rts.length;
      _passed = acc >= StudyConfig.passAccuracy;
      _stage = _Stage.result;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final result = _passed ? 'Passed' : 'Failed';
    final data = <String, dynamic>{
      'savedAt': Timestamp.now(),
      'day': widget.day,
      'phase': widget.phase,
      'result': result,
      'accuracyPct': double.parse((_accuracy * 100).toStringAsFixed(1)),
      'hits': _hits,
      'misses': _misses,
      'falseAlarms': _falseAlarms,
      'correctRejections': _correctRejections,
      'avgReactionMs': _avgRt == null ? null : double.parse(_avgRt!.toStringAsFixed(0)),
      'trials': _n,
      'scoredTrials': _n - 1,
      'alertness': _alertness.round(),
      'fatigue': _fatigue.round(),
      'stress': _stress.round(),
    };
    final status = await FirestoreService.saveGameScore(
      uid: widget.uid,
      day: widget.day,
      phase: widget.phase,
      data: data,
    );
    if (!mounted) return;
    if (status == WriteStatus.failed) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not save. Check your connection / Firestore rules and try again.'),
      ));
      return;
    }
    await widget.progress.markDone(widget.day, widget.phase);
    await widget.progress.setScoreText(
        widget.day, widget.phase, '$result ${(_accuracy * 100).toStringAsFixed(0)}%');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(status == WriteStatus.confirmed
          ? 'Score saved.'
          : 'Saved on this phone — will sync when online.'),
    ));
    Navigator.of(context).pop(true);
  }

  Future<void> _confirmQuit() async {
    final quit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quit the puzzle?'),
        content: const Text('This attempt will be discarded and nothing will be saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Continue')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Quit')),
        ],
      ),
    );
    if (quit == true && mounted) {
      _ticker?.cancel();
      Navigator.of(context).pop(false);
    }
  }

  String _mmss(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _stage == _Stage.intro,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_stage == _Stage.playing) {
          await _confirmQuit();
        } else if (_stage == _Stage.result && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Please save your result first.')));
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Day ${widget.day} · $_title'),
          automaticallyImplyLeading: _stage == _Stage.intro,
        ),
        body: SafeArea(
          child: switch (_stage) {
            _Stage.intro => _intro(),
            _Stage.playing => _playing(),
            _Stage.result => _result(),
          },
        ),
      ),
    );
  }

  Widget _intro() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.grid_view_rounded, size: 72),
          const SizedBox(height: 16),
          Text('Visual memory puzzle (1-back)',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          const Text(
            '• A square lights up briefly every 5 seconds.\n'
            '• If it is in the SAME place as the previous square, tap "SAME".\n'
            '• If it is in a different place, do nothing.\n'
            '• The first square is just for watching.\n'
            '• It lasts 5 minutes (60 squares). You can only play once per session.',
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _start,
            child: const Padding(padding: EdgeInsets.all(14), child: Text('Start (5 min)')),
          ),
        ],
      ),
    );
  }

  Widget _playing() {
    final cs = Theme.of(context).colorScheme;
    final responded = _pressed[_trial];
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Square ${_trial + 1} / $_n'),
              Text(_mmss(_remainingSec), style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _clock.elapsedMilliseconds / _totalMs, minHeight: 6),
          const Spacer(),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: AspectRatio(
              aspectRatio: 1,
              child: GridView.count(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                physics: const NeverScrollableScrollPhysics(),
                children: List.generate(9, (i) {
                  final lit = _stimOn && _positions[_trial] == i;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 80),
                    decoration: BoxDecoration(
                      color: lit ? cs.primary : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                  );
                }),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 22,
            child: Text(
              _trial == 0
                  ? 'Watch the first square…'
                  : (responded ? 'Response recorded' : ''),
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 68,
            child: FilledButton(
              onPressed: _trial == 0 ? null : _onMatch,
              child: const Text('SAME as previous', style: TextStyle(fontSize: 20)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(k), Text(v, style: const TextStyle(fontWeight: FontWeight.w600))],
        ),
      );

  Widget _slider(String label, double v, ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${v.round()} / 5'),
        Slider(value: v, min: 1, max: 5, divisions: 4, label: v.round().toString(), onChanged: onChanged),
      ],
    );
  }

  Widget _result() {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Icon(_passed ? Icons.check_circle : Icons.cancel,
            size: 72, color: _passed ? Colors.green : cs.error),
        const SizedBox(height: 8),
        Text(_passed ? 'Passed' : 'Failed',
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _statRow('Accuracy', '${(_accuracy * 100).toStringAsFixed(1)}%'),
                _statRow('Hits', '$_hits'),
                _statRow('Misses', '$_misses'),
                _statRow('False alarms', '$_falseAlarms'),
                _statRow('Avg reaction time',
                    _avgRt == null ? 'Not available' : '${_avgRt!.toStringAsFixed(0)} ms'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text('How do you feel right now?', style: Theme.of(context).textTheme.titleMedium),
        _slider('Alertness', _alertness, (v) => setState(() => _alertness = v)),
        _slider('Fatigue', _fatigue, (v) => setState(() => _fatigue = v)),
        _slider('Stress', _stress, (v) => setState(() => _stress = v)),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save & finish'),
          ),
        ),
      ],
    );
  }
}
