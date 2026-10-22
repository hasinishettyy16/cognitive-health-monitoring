// =============================================================================
// Cognitive Readiness Estimation — Flutter frontend (single file)
//
// Talks to the FastAPI backend:
//   GET  /health     -> backend status
//   POST /calculate  -> features + experimental CRI scores
//
// The CRI is NEVER computed here. Every score on screen comes from the backend.
// Missing values are shown as "Not available", never as 0.
//
// Only extra dependency:  flutter pub add http
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

// =============================================================================
// 1. CONFIG — the ONLY place the backend URL lives
// =============================================================================
class ApiConfig {
  ApiConfig._();

  /// Override at launch:  flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
  static const String _envUrl = String.fromEnvironment('API_BASE_URL');

  /// Set from the in-app "Backend URL" dialog (kept in memory only).
  static String? runtimeOverride;

  static String get baseUrl {
    final o = runtimeOverride;
    if (o != null && o.trim().isNotEmpty) return _clean(o);
    if (_envUrl.isNotEmpty) return _clean(_envUrl);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8000'; // Android emulator -> host computer
    }
    return 'http://127.0.0.1:8000'; // iOS simulator / desktop / web
  }

  static String _clean(String u) {
    var s = u.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static const Duration healthTimeout = Duration(seconds: 5);
  static const Duration calculateTimeout = Duration(seconds: 30);

  /// UI-only hint: show a data-quality warning below this signal quality (0–1).
  static const double lowSignalQuality = 0.6;

  static const List<String> phases = ['pre', 'during', 'post'];
  static const int maxStudyDay = 15;
}

// =============================================================================
// 2. HELPERS
// =============================================================================
double? _toDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

Map<String, dynamic> _asMap(dynamic v) {
  if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
  return <String, dynamic>{};
}

String _isoDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
}

String formatValue(dynamic v) {
  if (v == null) return 'Not available';
  if (v is bool) return v ? 'Yes' : 'No';
  if (v is int) return v.toString();
  if (v is double) {
    if (!v.isFinite) return 'Not available';
    var s = v.toStringAsFixed(3);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      s = s.replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }
  if (v is String) return v.trim().isEmpty ? 'Not available' : v;
  if (v is List) return '${v.length} items';
  return v.toString();
}

bool _isMissing(dynamic v) {
  if (v == null) return true;
  if (v is double && !v.isFinite) return true;
  if (v is String && v.trim().isEmpty) return true;
  return false;
}

String prettyLabel(String key) {
  final s = key
      .replaceAll('_experimental', '')
      .replaceAll('.', ' · ')
      .replaceAll('_', ' ')
      .trim();
  const acronyms = {
    'rmssd', 'sdnn', 'hr', 'hrv', 'gsr', 'eda', 'ppg', 'imu', 'cri', 'ms', 'bpm', 'rt', 'rms'
  };
  return s.split(RegExp(r'\s+')).map((w) {
    if (w.isEmpty || w == '·') return w;
    if (acronyms.contains(w.toLowerCase())) return w.toUpperCase();
    return w[0].toUpperCase() + w.substring(1);
  }).join(' ');
}

/// Unit only where the key itself says so. Never guessed (GSR unit is unknown).
String? unitFor(String path) {
  final k = path.toLowerCase();
  if (k.contains('score')) return null;
  if (k.endsWith('_bpm')) return 'bpm';
  if (k.endsWith('_ms') || k.contains('rmssd') || k.contains('sdnn')) return 'ms';
  if (k.endsWith('_pct') || k.endsWith('_percent')) return '%';
  return null;
}

double _unit(double v) {
  final x = v / 100;
  if (x.isNaN) return 0.0;
  return math.min(1.0, math.max(0.0, x));
}

// =============================================================================
// 3. REQUEST MODEL
// =============================================================================
enum PayloadSource { none, synthetic, pasted }

class SessionPayload {
  final String participantId;
  final DateTime sessionDate;
  final int interventionDay;
  final String phase;
  final List<Map<String, dynamic>> sensorReadings;
  final List<Map<String, dynamic>> cognitiveTrials;

  const SessionPayload({
    required this.participantId,
    required this.sessionDate,
    required this.interventionDay,
    required this.phase,
    required this.sensorReadings,
    required this.cognitiveTrials,
  });

  /// Drops null / non-finite values so missing data is OMITTED, never sent as 0.
  static Map<String, dynamic> _clean(Map<String, dynamic> m) {
    final out = <String, dynamic>{};
    m.forEach((k, v) {
      if (v == null) return;
      if (v is double && !v.isFinite) return;
      out[k] = v;
    });
    return out;
  }

  Map<String, dynamic> toJson() => {
        'participant_id': participantId.trim(),
        'session_date': _isoDate(sessionDate),
        'intervention_day': interventionDay,
        'phase': phase,
        'sensor_readings': sensorReadings.map(_clean).toList(),
        'cognitive_trials': cognitiveTrials.map(_clean).toList(),
      };

  List<String> validate() {
    final e = <String>[];
    if (participantId.trim().isEmpty) e.add('Participant ID is required.');
    if (interventionDay < 1) e.add('Intervention day must be 1 or more.');
    if (!ApiConfig.phases.contains(phase)) e.add('Phase must be pre, during or post.');
    if (sensorReadings.isEmpty && cognitiveTrials.isEmpty) {
      e.add('No sensor readings and no cognitive trials to send.');
    }
    return e;
  }

  static bool _hasAny(List<Map<String, dynamic>> rows, List<String> keys) =>
      rows.any((r) => keys.any((k) => !_isMissing(r[k])));

  List<String> warnings() {
    final w = <String>[];
    if (sensorReadings.isEmpty) {
      w.add('No sensor readings — physiological, GSR and movement features will be unavailable.');
    } else {
      if (!_hasAny(sensorReadings, ['heart_rate_bpm', 'ppg_interval_ms'])) {
        w.add('No heart-rate / PPG interval values — HRV features will be unavailable.');
      }
      if (!_hasAny(sensorReadings, ['gsr_value'])) {
        w.add('No GSR/EDA values in this session (GSR is not part of the CRI yet).');
      }
      if (!_hasAny(sensorReadings,
          ['accel_x', 'accel_y', 'accel_z', 'gyro_x', 'gyro_y', 'gyro_z'])) {
        w.add('No IMU values — movement features will be unavailable.');
      }
    }
    if (cognitiveTrials.isEmpty) {
      w.add('No cognitive trials — cognitive features will be unavailable.');
    }
    return w;
  }
}

// =============================================================================
// 4. RESPONSE MODEL (defensive: backend keys are read dynamically)
// =============================================================================
enum FeatureGroup { physiology, eda, movement, cognitive, quality, other }

extension FeatureGroupX on FeatureGroup {
  String get title => switch (this) {
        FeatureGroup.physiology => 'Physiological features',
        FeatureGroup.eda => 'GSR / EDA features',
        FeatureGroup.movement => 'Movement features',
        FeatureGroup.cognitive => 'Cognitive performance',
        FeatureGroup.quality => 'Data quality',
        FeatureGroup.other => 'Other features',
      };

  IconData get icon => switch (this) {
        FeatureGroup.physiology => Icons.favorite_border,
        FeatureGroup.eda => Icons.water_drop_outlined,
        FeatureGroup.movement => Icons.directions_run,
        FeatureGroup.cognitive => Icons.psychology_outlined,
        FeatureGroup.quality => Icons.verified_outlined,
        FeatureGroup.other => Icons.list_alt,
      };

  String? get note => switch (this) {
        FeatureGroup.eda =>
          'Shown for information only — GSR/EDA is not yet part of the CRI (pending backend update).',
        _ => null,
      };
}

FeatureGroup groupOf(String path) {
  final k = path.toLowerCase();
  bool has(String p) => RegExp(p).hasMatch(k);
  if (has(r'quality')) return FeatureGroup.quality;
  if (has(r'gsr|eda|skin')) return FeatureGroup.eda;
  if (has(r'accel|gyro|movement|motion|imu|artefact|artifact')) return FeatureGroup.movement;
  if (has(r'accuracy|reaction|hit|miss|false|trial|correct|omission|commission|target|response|(^|[_.])rt([_.]|$)')) {
    return FeatureGroup.cognitive;
  }
  if (has(r'heart|hrv|rmssd|sdnn|pnn|ppg|(^|[_.])(hr|bpm|ibi|rr|nn)([_.]|$)')) {
    return FeatureGroup.physiology;
  }
  return FeatureGroup.other;
}

class FeatureEntry {
  final String path;
  final dynamic value;
  const FeatureEntry(this.path, this.value);
}

List<FeatureEntry> flattenFeatures(Map<String, dynamic> m, [String prefix = '']) {
  final out = <FeatureEntry>[];
  m.forEach((k, v) {
    final path = prefix.isEmpty ? k : '$prefix.$k';
    if (v is Map) {
      out.addAll(flattenFeatures(_asMap(v), path));
    } else {
      out.add(FeatureEntry(path, v));
    }
  });
  return out;
}

class CriResult {
  final Map<String, dynamic> raw;
  final Map<String, dynamic> session;
  final Map<String, dynamic> features;
  final Map<String, dynamic> scores;
  final String? disclaimer;

  const CriResult({
    required this.raw,
    required this.session,
    required this.features,
    required this.scores,
    required this.disclaimer,
  });

  factory CriResult.fromJson(Map<String, dynamic> j) {
    final d = j['disclaimer'];
    return CriResult(
      raw: j,
      session: _asMap(j['session']),
      features: _asMap(j['features']),
      scores: _asMap(j['scores']),
      disclaimer: (d is String && d.trim().isNotEmpty) ? d : null,
    );
  }

  double? _score(String key) => _toDouble(scores[key]);

  double? get cri {
    final direct = _score('cri_experimental');
    if (direct != null) return direct;
    for (final e in scores.entries) {
      if (e.key.toLowerCase().contains('cri')) {
        final v = _toDouble(e.value);
        if (v != null) return v;
      }
    }
    return null;
  }

  double? get physiologyScore => _score('physiology_score_experimental');
  double? get cognitiveScore => _score('cognitive_score_experimental');

  String? get status {
    for (final c in [scores['score_status'], features['score_status'], raw['score_status']]) {
      if (c is String && c.trim().isNotEmpty) return c;
    }
    return null;
  }

  static const _mainScoreKeys = {
    'cri_experimental',
    'physiology_score_experimental',
    'cognitive_score_experimental',
    'score_status',
  };

  /// Other numeric/null `*score*` entries (e.g. rmssd_score_experimental).
  List<MapEntry<String, double?>> get componentScores {
    final out = <MapEntry<String, double?>>[];
    for (final e in scores.entries) {
      if (_mainScoreKeys.contains(e.key)) continue;
      if (e.value is Map || e.value is List) continue;
      if (e.value is String) continue;
      if (!e.key.toLowerCase().contains('score')) continue;
      out.add(MapEntry(e.key, _toDouble(e.value)));
    }
    return out;
  }

  /// Non-numeric extras inside `scores` (strings/bools), excluding status.
  List<MapEntry<String, dynamic>> get scoreInfo => scores.entries
      .where((e) => !_mainScoreKeys.contains(e.key) && (e.value is String || e.value is bool))
      .toList();

  Map<FeatureGroup, List<FeatureEntry>> get groupedFeatures {
    final out = <FeatureGroup, List<FeatureEntry>>{};
    for (final f in flattenFeatures(features)) {
      if (f.path.toLowerCase() == 'score_status') continue;
      out.putIfAbsent(groupOf(f.path), () => []).add(f);
    }
    return out;
  }

  double? get signalQuality {
    for (final f in flattenFeatures(features)) {
      if (f.path.toLowerCase().contains('signal_quality')) {
        final v = _toDouble(f.value);
        if (v != null) return v;
      }
    }
    return null;
  }

  int get missingFeatureCount =>
      flattenFeatures(features).where((f) => _isMissing(f.value)).length;
}

// =============================================================================
// 5. API CLIENT
// =============================================================================
enum ApiErrorKind { client, unreachable, timeout, validation, server, badResponse }

class ApiException implements Exception {
  final ApiErrorKind kind;
  final String message;
  final int? status;
  const ApiException(this.kind, this.message, [this.status]);

  @override
  String toString() => message;
}

class HealthResult {
  final bool ok;
  final String detail;
  const HealthResult(this.ok, this.detail);
}

class CriApi {
  CriApi({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  void close() => _client.close();

  Future<HealthResult> health() async {
    try {
      final r = await _client
          .get(Uri.parse('${ApiConfig.baseUrl}/health'))
          .timeout(ApiConfig.healthTimeout);
      if (r.statusCode != 200) return HealthResult(false, 'HTTP ${r.statusCode}');
      String? status;
      try {
        final j = jsonDecode(r.body);
        if (j is Map) status = j['status']?.toString();
      } catch (_) {}
      return HealthResult(status == null || status == 'ok', status ?? 'ok');
    } on TimeoutException {
      return const HealthResult(false, 'Timed out');
    } catch (_) {
      return const HealthResult(false, 'Unreachable');
    }
  }

  Future<CriResult> calculate(SessionPayload p) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/calculate');
    final body = jsonEncode(p.toJson());

    http.Response res;
    try {
      res = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: body,
          )
          .timeout(ApiConfig.calculateTimeout);
    } on TimeoutException {
      throw ApiException(ApiErrorKind.timeout,
          'The backend did not answer within ${ApiConfig.calculateTimeout.inSeconds} seconds.');
    } on http.ClientException {
      throw ApiException(ApiErrorKind.unreachable,
          'Cannot reach the backend at ${ApiConfig.baseUrl}. Is it running, and is the URL right for this device?');
    }

    if (res.statusCode == 200) {
      dynamic j;
      try {
        j = jsonDecode(utf8.decode(res.bodyBytes));
      } catch (_) {
        throw const ApiException(ApiErrorKind.badResponse, 'The backend returned invalid JSON.');
      }
      if (j is! Map) {
        throw const ApiException(
            ApiErrorKind.badResponse, 'The backend response was not a JSON object.');
      }
      return CriResult.fromJson(_asMap(j));
    }

    final detail = _detail(res);
    if (res.statusCode == 422 || res.statusCode == 400) {
      throw ApiException(ApiErrorKind.validation,
          'The backend rejected the data (HTTP ${res.statusCode}).\n$detail', res.statusCode);
    }
    throw ApiException(ApiErrorKind.server,
        'Backend error (HTTP ${res.statusCode}).\n$detail', res.statusCode);
  }

  String _detail(http.Response res) {
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is Map && j['detail'] != null) {
        final d = j['detail'];
        if (d is String) return d;
        if (d is List) {
          return d.map((e) {
            if (e is Map) {
              final loc = (e['loc'] is List)
                  ? (e['loc'] as List).where((x) => x.toString() != 'body').join('.')
                  : '';
              final msg = e['msg']?.toString() ?? e.toString();
              return loc.isEmpty ? msg : '$loc: $msg';
            }
            return e.toString();
          }).join('\n');
        }
        return d.toString();
      }
    } catch (_) {}
    final t = utf8.decode(res.bodyBytes, allowMalformed: true).trim();
    return t.length > 300 ? '${t.substring(0, 300)}…' : t;
  }
}

// =============================================================================
// 6. SYNTHETIC TEST DATA (clearly labelled in the UI — NOT participant data)
// =============================================================================
class SyntheticSession {
  final List<Map<String, dynamic>> sensors;
  final List<Map<String, dynamic>> trials;
  const SyntheticSession(this.sensors, this.trials);

  static double _r(double v, [int d = 3]) => double.parse(v.toStringAsFixed(d));

  factory SyntheticSession.build({int seed = 42, int rows = 120, int trials = 60}) {
    final rnd = math.Random(seed);
    double n(double amp) => (rnd.nextDouble() * 2 - 1) * amp;

    final sensors = <Map<String, dynamic>>[];
    for (var i = 0; i < rows; i++) {
      final hr = 72 + 4 * math.sin(i / 10) + n(1.5);
      sensors.add({
        'heart_rate_bpm': _r(hr, 1),
        'ppg_interval_ms': _r(60000 / hr + n(15), 1),
        'gsr_value': _r(2.1 + 0.2 * math.sin(i / 20) + n(0.03)),
        'gsr_unit': 'unknown',
        'accel_x': _r(0.01 + n(0.02)),
        'accel_y': _r(0.02 + n(0.02)),
        'accel_z': _r(0.99 + n(0.02)),
        'gyro_x': _r(0.1 + n(0.05)),
        'gyro_y': _r(0.1 + n(0.05)),
        'gyro_z': _r(0.1 + n(0.05)),
        'signal_quality': _r(0.9 + rnd.nextDouble() * 0.09),
      });
    }

    final t = <Map<String, dynamic>>[];
    for (var i = 0; i < trials; i++) {
      final isTarget = i > 0 && rnd.nextDouble() < 0.30 ? 1 : 0;
      final responded = isTarget == 1 ? rnd.nextDouble() < 0.85 : rnd.nextDouble() < 0.08;
      final resp = responded ? 1 : 0;
      t.add({
        'is_target': isTarget,
        'response_made': resp,
        'correct': resp == isTarget ? 1 : 0,
        'reaction_time_ms': responded ? _r(350 + rnd.nextDouble() * 250, 0) : null,
      });
    }
    return SyntheticSession(sensors, t);
  }
}

// =============================================================================
// 7. APP + DASHBOARD
// =============================================================================
enum _Stage { idle, loading, error, result }

enum _Health { checking, online, offline }

class CriDashboardPage extends StatefulWidget {
  const CriDashboardPage({super.key});

  @override
  State<CriDashboardPage> createState() => _CriDashboardPageState();
}

class _CriDashboardPageState extends State<CriDashboardPage> {
  final CriApi _api = CriApi();
  final TextEditingController _participant = TextEditingController();

  DateTime _date = DateTime.now();
  int _day = 1;
  String _phase = 'pre';
  List<Map<String, dynamic>> _sensors = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _trials = <Map<String, dynamic>>[];
  PayloadSource _source = PayloadSource.none;

  _Stage _stage = _Stage.idle;
  _Health _health = _Health.checking;
  ApiException? _error;
  CriResult? _result;
  PayloadSource _resultSource = PayloadSource.none;
  List<String> _warnings = <String>[];
  Map<String, dynamic>? _lastRequest;

  @override
  void initState() {
    super.initState();
    _checkHealth();
  }

  @override
  void dispose() {
    _participant.dispose();
    _api.close();
    super.dispose();
  }

  // ---------------- actions ----------------

  Future<void> _checkHealth() async {
    setState(() => _health = _Health.checking);
    final r = await _api.health();
    if (!mounted) return;
    setState(() => _health = r.ok ? _Health.online : _Health.offline);
  }

  void _loadSynthetic() {
    final s = SyntheticSession.build();
    setState(() {
      _sensors = s.sensors;
      _trials = s.trials;
      _source = PayloadSource.synthetic;
      if (_participant.text.trim().isEmpty) _participant.text = 'TEST001';
      _stage = _Stage.idle;
      _result = null;
      _error = null;
    });
  }

  SessionPayload _buildPayload() => SessionPayload(
        participantId: _participant.text,
        sessionDate: _date,
        interventionDay: _day,
        phase: _phase,
        sensorReadings: _sensors,
        cognitiveTrials: _trials,
      );

  Future<void> _calculate() async {
    final payload = _buildPayload();
    final problems = payload.validate();
    if (problems.isNotEmpty) {
      setState(() {
        _error = ApiException(ApiErrorKind.client, problems.join('\n'));
        _stage = _Stage.error;
      });
      return;
    }

    setState(() {
      _stage = _Stage.loading;
      _error = null;
      _warnings = payload.warnings();
      _lastRequest = payload.toJson();
    });

    try {
      final res = await _api.calculate(payload);
      if (!mounted) return;
      setState(() {
        _result = res;
        _resultSource = _source;
        _stage = _Stage.result;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _stage = _Stage.error;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = ApiException(ApiErrorKind.client, 'Unexpected error: $e');
        _stage = _Stage.error;
      });
    }
  }

  String? _applyPastedJson(String text) {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return 'That is not valid JSON.';
    }
    if (decoded is! Map) return 'The top level must be a JSON object.';
    final m = _asMap(decoded);

    List<Map<String, dynamic>> rows(String key) {
      final v = m[key];
      if (v == null) return <Map<String, dynamic>>[];
      if (v is! List) throw FormatException('"$key" must be a list.');
      return v.map((e) {
        if (e is! Map) throw FormatException('Every item in "$key" must be an object.');
        return _asMap(e);
      }).toList();
    }

    try {
      final s = rows('sensor_readings');
      final t = rows('cognitive_trials');
      if (s.isEmpty && t.isEmpty) {
        return 'No "sensor_readings" or "cognitive_trials" found.';
      }
      setState(() {
        _sensors = s;
        _trials = t;
        _source = PayloadSource.pasted;
        final pid = m['participant_id'];
        if (pid is String && pid.trim().isNotEmpty) _participant.text = pid.trim();
        final d = m['session_date'];
        if (d is String) {
          final p = DateTime.tryParse(d);
          if (p != null) _date = p;
        }
        final day = _toDouble(m['intervention_day']);
        if (day != null && day >= 1) _day = day.toInt();
        final ph = m['phase'];
        if (ph is String && ApiConfig.phases.contains(ph)) _phase = ph;
        _stage = _Stage.idle;
        _result = null;
        _error = null;
      });
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  Future<void> _openPasteDialog() async {
    final ctrl = TextEditingController();
    String? err;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Paste session JSON'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ctrl,
                  maxLines: 9,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: '{"participant_id": "...", "sensor_readings": [...], "cognitive_trials": [...]}',
                    errorText: err,
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      final c = await Clipboard.getData('text/plain');
                      if (c?.text != null) ctrl.text = c!.text!;
                    },
                    icon: const Icon(Icons.content_paste, size: 18),
                    label: const Text('Paste from clipboard'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final e = _applyPastedJson(ctrl.text);
                if (e == null) {
                  Navigator.pop(ctx);
                } else {
                  setD(() => err = e);
                }
              },
              child: const Text('Use this data'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openUrlDialog() async {
    final ctrl = TextEditingController(text: ApiConfig.baseUrl);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backend URL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            const Text(
              'Android emulator: http://10.0.2.2:8000\n'
              'iOS simulator / web: http://127.0.0.1:8000\n'
              'Physical phone: http://<computer-LAN-IP>:8000',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              ApiConfig.runtimeOverride = ctrl.text;
              Navigator.pop(ctx);
              _checkHealth();
            },
            child: const Text('Save & test'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2024),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _date = d);
  }

  void _copy(String label, Object data) {
    Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(data)));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$label copied to clipboard')));
  }

  // ---------------- build ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cognitive Readiness'),
        actions: [
          _healthChip(),
          IconButton(
            tooltip: 'Backend URL',
            icon: const Icon(Icons.settings_ethernet),
            onPressed: _openUrlDialog,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _inputCard(),
              const SizedBox(height: 12),
              _stateArea(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _healthChip() {
    late Color c;
    late String t;
    switch (_health) {
      case _Health.checking:
        c = Colors.grey;
        t = 'Checking…';
        break;
      case _Health.online:
        c = Colors.green;
        t = 'Backend online';
        break;
      case _Health.offline:
        c = Colors.red;
        t = 'Backend offline';
        break;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: ApiConfig.baseUrl,
        child: ActionChip(
          avatar: Icon(Icons.circle, size: 12, color: c),
          label: Text(t, style: const TextStyle(fontSize: 12)),
          visualDensity: VisualDensity.compact,
          onPressed: _checkHealth,
        ),
      ),
    );
  }

  Widget _inputCard() {
    final hasData = _sensors.isNotEmpty || _trials.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Session input', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _participant,
              decoration: const InputDecoration(
                labelText: 'Participant ID',
                helperText: 'Pseudonymous ID only (e.g. P01) — never a real name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(_isoDate(_date)),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.remove),
                        onPressed: _day > 1 ? () => setState(() => _day--) : null,
                      ),
                      Text('Day $_day'),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.add),
                        onPressed: _day < ApiConfig.maxStudyDay ? () => setState(() => _day++) : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'pre', label: Text('Pre')),
                ButtonSegment(value: 'during', label: Text('During')),
                ButtonSegment(value: 'post', label: Text('Post')),
              ],
              selected: {_phase},
              onSelectionChanged: (s) => setState(() => _phase = s.first),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Chip(
                  avatar: const Icon(Icons.sensors, size: 16),
                  label: Text('${_sensors.length} sensor rows'),
                  visualDensity: VisualDensity.compact,
                ),
                Chip(
                  avatar: const Icon(Icons.grid_view, size: 16),
                  label: Text('${_trials.length} cognitive trials'),
                  visualDensity: VisualDensity.compact,
                ),
                if (_source == PayloadSource.synthetic)
                  Chip(
                    avatar: Icon(Icons.science, size: 16, color: Colors.orange.shade800),
                    label: const Text('SYNTHETIC test data'),
                    backgroundColor: Colors.orange.shade50,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _loadSynthetic,
                  icon: const Icon(Icons.science_outlined, size: 18),
                  label: const Text('Synthetic test data'),
                ),
                OutlinedButton.icon(
                  onPressed: _openPasteDialog,
                  icon: const Icon(Icons.data_object, size: 18),
                  label: const Text('Paste session JSON'),
                ),
                FilledButton.icon(
                  onPressed: (!hasData || _stage == _Stage.loading) ? null : _calculate,
                  icon: const Icon(Icons.calculate_outlined, size: 18),
                  label: const Text('Calculate CRI'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stateArea() {
    switch (_stage) {
      case _Stage.idle:
        return _infoCard(
          Icons.insights,
          'No result yet',
          'Load a session (synthetic test data or pasted JSON) and tap "Calculate CRI". '
              'Scores are computed by the Python backend; nothing is calculated in the app.',
        );
      case _Stage.loading:
        return const Card(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Column(
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Calculating on the backend…'),
              ],
            ),
          ),
        );
      case _Stage.error:
        return _errorCard(_error!);
      case _Stage.result:
        return _resultView(_result!);
    }
  }

  Widget _infoCard(IconData icon, String title, String text) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 28, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(text),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard(ApiException e) {
    final (IconData icon, String title) = switch (e.kind) {
      ApiErrorKind.unreachable => (Icons.cloud_off, 'Backend unavailable'),
      ApiErrorKind.timeout => (Icons.timer_off, 'Backend timed out'),
      ApiErrorKind.validation => (Icons.rule, 'Invalid or incomplete data'),
      ApiErrorKind.client => (Icons.edit_note, 'Check your input'),
      ApiErrorKind.badResponse => (Icons.report_gmailerrorred, 'Unexpected response'),
      ApiErrorKind.server => (Icons.error_outline, 'Backend error'),
    };
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: cs.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(color: cs.onErrorContainer)),
              ),
            ]),
            const SizedBox(height: 8),
            Text(e.message, style: TextStyle(color: cs.onErrorContainer)),
            const SizedBox(height: 12),
            Row(children: [
              if (e.kind != ApiErrorKind.client)
                FilledButton.tonalIcon(
                  onPressed: _calculate,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Retry'),
                ),
              if (e.kind == ApiErrorKind.unreachable || e.kind == ApiErrorKind.timeout) ...[
                const SizedBox(width: 8),
                TextButton(onPressed: _openUrlDialog, child: const Text('Change URL')),
              ],
              if (_lastRequest != null && e.kind == ApiErrorKind.validation) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _copy('Request JSON', _lastRequest!),
                  child: const Text('Copy request'),
                ),
              ],
            ]),
          ],
        ),
      ),
    );
  }

  // ---------------- result dashboard ----------------

  Widget _resultView(CriResult r) {
    final groups = r.groupedFeatures;
    final warnings = <String>[..._warnings];
    final sq = r.signalQuality;
    if (sq != null && sq <= 1 && sq < ApiConfig.lowSignalQuality) {
      warnings.add('Mean signal quality is low (${formatValue(sq)}) — treat results with caution.');
    }
    final missing = r.missingFeatureCount;
    if (missing > 0) {
      warnings.add('$missing feature value(s) were unavailable and are shown as "Not available".');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (warnings.isNotEmpty) _warningsCard(warnings),
        _topCard(r),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _miniScore('Physiology score', r.physiologyScore, Icons.monitor_heart_outlined)),
            const SizedBox(width: 8),
            Expanded(child: _miniScore('Cognitive score', r.cognitiveScore, Icons.psychology_outlined)),
          ],
        ),
        const SizedBox(height: 8),
        for (final g in FeatureGroup.values)
          if (groups[g] != null && groups[g]!.isNotEmpty) _featureSection(g, groups[g]!),
        if (groups.isEmpty)
          _infoCard(Icons.list_alt, 'No features returned', 'The backend response had no "features" object.'),
        if (r.componentScores.isNotEmpty) _componentScoresCard(r),
        _explanationCard(),
        _sessionCard(r),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: _lastRequest == null ? null : () => _copy('Request JSON', _lastRequest!),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy request JSON'),
            ),
            TextButton.icon(
              onPressed: () => _copy('Response JSON', r.raw),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy response JSON'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _warningsCard(List<String> items) {
    return Card(
      color: Colors.amber.shade50,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.warning_amber_rounded, color: Colors.amber.shade900),
              const SizedBox(width: 8),
              Text('Data notes', style: Theme.of(context).textTheme.titleSmall),
            ]),
            const SizedBox(height: 6),
            for (final w in items)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('• $w', style: const TextStyle(fontSize: 13)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _topCard(CriResult r) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _ScoreRing(value: r.cri),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Experimental CRI', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 2),
                  Text(
                    'Rule-based research score — not an ML prediction, not a clinical or diagnostic measure.',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    if (r.status != null)
                      Chip(
                        label: Text('Status: ${r.status}'),
                        visualDensity: VisualDensity.compact,
                      ),
                    if (_resultSource == PayloadSource.synthetic)
                      Chip(
                        avatar: Icon(Icons.science, size: 16, color: Colors.orange.shade800),
                        label: const Text('Synthetic input — not participant results'),
                        backgroundColor: Colors.orange.shade50,
                        visualDensity: VisualDensity.compact,
                      ),
                  ]),
                  if (r.disclaimer != null) ...[
                    const SizedBox(height: 8),
                    Text(r.disclaimer!, style: const TextStyle(fontSize: 12)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniScore(String title, double? v, IconData icon) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(child: Text(title, style: const TextStyle(fontSize: 13))),
            ]),
            const SizedBox(height: 8),
            Text(
              v == null ? 'Not available' : '${formatValue(v)} / 100',
              style: v == null
                  ? TextStyle(fontStyle: FontStyle.italic, color: Colors.grey.shade600)
                  : Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: v == null ? 0 : _unit(v), minHeight: 6),
            const SizedBox(height: 2),
            Text('experimental', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }

  Widget _featureSection(FeatureGroup g, List<FeatureEntry> items) {
    return Card(
      child: ExpansionTile(
        initiallyExpanded: true,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(g.icon, color: Theme.of(context).colorScheme.primary),
        title: Text(g.title),
        subtitle: g.note == null ? null : Text(g.note!, style: const TextStyle(fontSize: 12)),
        children: [
          for (final f in items) _featureTile(f),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _featureTile(FeatureEntry f) {
    final missing = _isMissing(f.value);
    final unit = unitFor(f.path);
    return ListTile(
      dense: true,
      title: Text(prettyLabel(f.path)),
      trailing: missing
          ? Text('Not available',
              style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey.shade600))
          : Text(
              unit == null ? formatValue(f.value) : '${formatValue(f.value)} $unit',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
    );
  }

  Widget _componentScoresCard(CriResult r) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Component scores', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            for (final e in r.componentScores)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(prettyLabel(e.key), style: const TextStyle(fontSize: 13)),
                        e.value == null
                            ? Text('Not available',
                                style: TextStyle(
                                    fontStyle: FontStyle.italic, color: Colors.grey.shade600))
                            : Text(formatValue(e.value),
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(value: e.value == null ? 0 : _unit(e.value!), minHeight: 6),
                  ],
                ),
              ),
            for (final e in r.scoreInfo)
              Text('${prettyLabel(e.key)}: ${formatValue(e.value)}',
                  style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _explanationCard() {
    return _infoCard(
      Icons.help_outline,
      'How to read this',
      'All scores are produced by the backend\'s experimental, rule-based calculator. '
          'The current API response does not include the formula, weights or per-feature '
          'contributions, so none are shown here. These need a backend update first: '
          'feature-level explanations, threshold metadata, missingness flags and weighted contributions.',
    );
  }

  Widget _sessionCard(CriResult r) {
    if (r.session.isEmpty) return const SizedBox.shrink();
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.badge_outlined),
        title: const Text('Session details (from backend)'),
        children: [
          for (final f in flattenFeatures(r.session))
            ListTile(
              dense: true,
              title: Text(prettyLabel(f.path)),
              trailing: Text(formatValue(f.value)),
            ),
        ],
      ),
    );
  }
}

class _ScoreRing extends StatelessWidget {
  final double? value;
  const _ScoreRing({required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 128,
      height: 128,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: value == null ? 0 : _unit(value!),
              strokeWidth: 12,
              backgroundColor: cs.surfaceContainerHighest,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value == null ? '—' : formatValue(value),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              Text('/ 100', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}
