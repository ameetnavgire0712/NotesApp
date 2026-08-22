// ignore_for_file: deprecated_member_use
/// Thin REST client for /api/v1/recap on the Cloudflare Worker.
/// Auth: reuses the Supabase access token directly.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/utils/responsive.dart';

import '../../core/config/app_config.dart';
import 'recap_models.dart';

class RecapApi {
  RecapApi();

  String? get _accessToken =>
      Supabase.instance.client.auth.currentSession?.accessToken;

  bool get _isAuthed => _accessToken != null;

  Map<String, String> _headers() {
    final token = _accessToken;
    final h = <String, String>{'Content-Type': 'application/json'};
    if (token != null) h['Authorization'] = 'Bearer $token';
    return h;
  }

  /// Fetch a recap for the given period. If [refresh] is true, the worker
  /// regenerates instead of returning the cached payload.
  Future<RecapPayload?> fetch(RecapPeriod period,
      {bool refresh = false}) async {
    if (!_isAuthed) return null;
    final qs = StringBuffer('?period=${period.apiValue}');
    if (refresh) qs.write('&refresh=1');
    final url = '${AppConfig.workerUrl}/api/v1/recap$qs';
    try {
      final r = await http
          .get(Uri.parse(url), headers: _headers())
          .timeout(const Duration(seconds: 90));
      if (r.statusCode != 200) {
        debugPrint('RecapApi.fetch HTTP ${r.statusCode}: ${r.body}');
        return null;
      }
      final decoded = json.decode(r.body);
      if (decoded is! Map) return null;
      if (decoded['error'] != null) {
        debugPrint('RecapApi.fetch err: ${decoded['error']}');
        return null;
      }
      return RecapPayload.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      debugPrint('RecapApi.fetch exception: $e');
      return null;
    }
  }

  /// Save the current recap to the user's profile.
  Future<bool> save(RecapPayload payload, {String? title}) async {
    if (!_isAuthed) return false;
    try {
      final r = await http
          .post(
            Uri.parse('${AppConfig.workerUrl}/api/v1/recap/save'),
            headers: _headers(),
            body: json.encode({
              'period': payload.period.apiValue,
              'period_start': payload.periodStart,
              'period_end': payload.periodEnd,
              'title': title,
              'payload': payload.toJsonForSave(),
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) {
        debugPrint('RecapApi.save HTTP ${r.statusCode}: ${r.body}');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('RecapApi.save exception: $e');
      return false;
    }
  }

  Future<List<SavedRecapSummary>> listSaved() async {
    if (!_isAuthed) return [];
    try {
      final r = await http
          .get(
            Uri.parse('${AppConfig.workerUrl}/api/v1/recap/saved'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) return [];
      final decoded = json.decode(r.body);
      if (decoded is! Map) return [];
      final items = (decoded['items'] as List?) ?? const [];
      return items
          .whereType<Map>()
          .map((m) => SavedRecapSummary.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } catch (e) {
      debugPrint('RecapApi.listSaved exception: $e');
      return [];
    }
  }

  Future<RecapPayload?> getSaved(String id) async {
    if (!_isAuthed) return null;
    try {
      final r = await http
          .get(
            Uri.parse('${AppConfig.workerUrl}/api/v1/recap/saved/$id'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) return null;
      final decoded = json.decode(r.body);
      if (decoded is! Map) return null;
      final payload = decoded['payload'];
      if (payload is! Map) return null;
      return RecapPayload.fromJson(Map<String, dynamic>.from(payload));
    } catch (e) {
      debugPrint('RecapApi.getSaved exception: $e');
      return null;
    }
  }

  Future<bool> deleteSaved(String id) async {
    if (!_isAuthed) return false;
    try {
      final r = await http
          .delete(
            Uri.parse('${AppConfig.workerUrl}/api/v1/recap/saved/$id'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
      return r.statusCode == 200;
    } catch (e) {
      debugPrint('RecapApi.deleteSaved exception: $e');
      return false;
    }
  }
}
