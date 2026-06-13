import 'dart:io';

import 'package:flutter/services.dart';

/// Bridges to native security-scoped bookmarks on macOS so a user-picked
/// output directory remains writable across app restarts.
///
/// Picking a folder via `file_picker` only grants write access for the rest
/// of the current process. [create] turns that grant into a bookmark that
/// can be persisted, and [resolve] (called on the next launch) restores
/// access from it. On non-macOS platforms both methods are no-ops.
class SecureBookmark {
  static const _channel = MethodChannel('porter/secure_bookmarks');

  /// Creates a bookmark for [path]. Must be called while the app still has
  /// access to [path] (e.g. immediately after the user picks it).
  static Future<String?> create(String path) async {
    if (!Platform.isMacOS) return null;
    try {
      return await _channel.invokeMethod<String>('createBookmark', {'path': path});
    } catch (_) {
      return null;
    }
  }

  /// Resolves [bookmark] and starts accessing the security-scoped resource
  /// for the remainder of this process. Returns the resolved path, or null
  /// if the bookmark could not be resolved.
  static Future<BookmarkResolution?> resolve(String bookmark) async {
    if (!Platform.isMacOS) return null;
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'resolveBookmark',
        {'bookmark': bookmark},
      );
      final path = result?['path'] as String?;
      if (path == null) return null;
      return BookmarkResolution(
        path: path,
        refreshedBookmark: result?['refreshedBookmark'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Result of resolving a security-scoped bookmark.
class BookmarkResolution {
  /// The resolved directory path, with access now active for this process.
  final String path;

  /// A re-created bookmark to persist if the original had gone stale (e.g.
  /// the directory was moved or renamed), or null if the original is still
  /// valid.
  final String? refreshedBookmark;

  BookmarkResolution({required this.path, this.refreshedBookmark});
}
