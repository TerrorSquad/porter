import 'dart:convert';

import 'package:http/http.dart' as http;

/// Mirrors `UploadResult` from `nodejs/src/lib/receiver.ts`'s `/upload` endpoint.
class RelayResult {
  final String? fileName;
  final String? path;
  final int? size;
  final bool? duplicate;
  final String? sha256;
  final String? transferId;
  final String? manifestPath;
  final bool? complete;
  final bool? verified;
  final String? joinedPath;
  final String? error;

  RelayResult({
    this.fileName,
    this.path,
    this.size,
    this.duplicate,
    this.sha256,
    this.transferId,
    this.manifestPath,
    this.complete,
    this.verified,
    this.joinedPath,
    this.error,
  });

  factory RelayResult.fromJson(Map<String, dynamic> json) {
    return RelayResult(
      fileName: json['fileName'] as String?,
      path: json['path'] as String?,
      size: json['size'] as int?,
      duplicate: json['duplicate'] as bool?,
      sha256: json['sha256'] as String?,
      transferId: json['transferId'] as String?,
      manifestPath: json['manifestPath'] as String?,
      complete: json['complete'] as bool?,
      verified: json['verified'] as bool?,
      joinedPath: json['joinedPath'] as String?,
    );
  }
}

class RelayService {
  /// POSTs a scanned QR payload to a `porter serve` instance's `/upload`
  /// endpoint. Network/parse errors are returned as `RelayResult(error: ...)`
  /// rather than thrown.
  static Future<RelayResult> upload(String relayUrl, String content) async {
    final base = relayUrl.replaceAll(RegExp(r'/$'), '');
    try {
      final response = await http.post(
        Uri.parse('$base/upload'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'content': content, 'format': 'QR_CODE'}),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = response.body.length > 120
            ? response.body.substring(0, 120)
            : response.body;
        return RelayResult(error: 'HTTP ${response.statusCode}: $body');
      }

      return RelayResult.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    } catch (e) {
      return RelayResult(error: e.toString());
    }
  }
}
