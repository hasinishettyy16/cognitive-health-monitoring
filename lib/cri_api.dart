
import 'dart:convert';
import 'package:http/http.dart' as http;

class CriApi {
  CriApi._();

  static const String baseUrl = 'http://10.0.2.2:8000';

  static Future<bool> checkHealth() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> calculate({
    required String participantId,
    required String sessionDate,
    required int interventionDay,
    required String phase,
    required List<Map<String, dynamic>> sensorReadings,
    required List<Map<String, dynamic>> cognitiveTrials,
  }) async {
    final payload = {
      'participant_id': participantId,
      'session_date': sessionDate,
      'intervention_day': interventionDay,
      'phase': phase,
      'sensor_readings': sensorReadings,
      'cognitive_trials': cognitiveTrials,
    };

    final response = await http
        .post(
          Uri.parse('$baseUrl/calculate'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw Exception(
        'CRI API error ${response.statusCode}: ${response.body}',
      );
    }

    final result = jsonDecode(response.body);
    if (result is! Map) {
      throw const FormatException('Invalid CRI response.');
    }

    return Map<String, dynamic>.from(result);
  }
}
