import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import '../models/chunk.dart';
import '../models/transfer.dart';
import 'chunk_parser.dart';

class Assembler {
  final Map<String, Transfer> transfers = {};
  Function(Transfer)? onProgress;
  Function(Transfer)? onComplete;
  Function(int)? onChunkBytes;
  Function(Transfer, int, List<int>)? onChunkReceived;

  Assembler({this.onProgress, this.onComplete, this.onChunkBytes});

  /// Process a raw QR string. Returns true if new data was ingested.
  bool ingest(String raw) {
    final parsed = ChunkParser.parseQR(raw);
    if (parsed == null) return false;

    if (parsed is ChecksumChunk) {
      final transfer = getOrCreate(parsed.id, 0, 'T');
      if (transfer.checksum == parsed.checksum) return false;
      transfer.checksum = parsed.checksum;
      if (transfer.assembled != null) {
        _verifyChecksum(transfer);
      } else {
        _tryComplete(transfer);
      }
      return true;
    }

    if (parsed is DataChunk) {
      final transfer = getOrCreate(parsed.id, parsed.total, parsed.mode);
      if (parsed.total > transfer.total) transfer.total = parsed.total;
      if (transfer.isComplete) return false;
      if (transfer.seenIndices.contains(parsed.index)) return false;

      final payload = _decodePayload(parsed.mode, parsed.payload);
      transfer.addChunk(parsed.index, payload);
      transfer.mode = parsed.mode;
      onChunkBytes?.call(payload.length);
      onChunkReceived?.call(transfer, parsed.index, payload);

      onProgress?.call(transfer);
      _tryComplete(transfer);
      return true;
    }

    return false;
  }

  Transfer getOrCreate(String id, int total, String mode) {
    return transfers.putIfAbsent(
      id,
      () => Transfer(id: id),
    );
  }

  void reset([String? id]) {
    if (id != null) {
      transfers.remove(id);
    } else {
      transfers.clear();
    }
  }

  void _tryComplete(Transfer t) {
    if (t.isComplete) {
      t.completedAt = DateTime.now();
      _assemble(t);
    }
  }

  void _assemble(Transfer t) {
    try {
      final parts = <List<int>>[];
      for (int i = 1; i <= t.total; i++) {
        final chunk = t.chunks[i];
        if (chunk == null) throw Exception('Missing chunk $i');
        parts.add(chunk);
      }

      List<int> assembled = [];
      for (final part in parts) {
        assembled.addAll(part);
      }

      if (t.mode == 'C') {
        // Gzip decompression
        assembled = GZipDecoder().decodeBytes(assembled);
      }

      t.assembled = assembled;
      _verifyChecksum(t);
    } catch (e) {
      t.error = 'Assembly failed: $e';
      onComplete?.call(t);
    }
  }

  void _verifyChecksum(Transfer t) {
    if (t.assembled == null || t.checksum == null) {
      onComplete?.call(t);
      return;
    }

    try {
      final actual = sha256.convert(t.assembled!).toString();
      t.verified = actual.toLowerCase() == t.checksum!.toLowerCase();
      if (!t.verified!) {
        t.error = 'SHA-256 mismatch: expected ${t.checksum}, got $actual';
      }
    } catch (e) {
      t.error = 'Checksum verification failed: $e';
    }

    onComplete?.call(t);
  }

  List<int> _decodePayload(String mode, String payload) {
    if (mode == 'T') {
      return utf8.encode(payload);
    }
    // B and C: base64-encoded
    return base64.decode(payload);
  }
}
