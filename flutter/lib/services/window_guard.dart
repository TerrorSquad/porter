import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Tells the macOS window whether a transfer is running, so closing the
/// window can ask for confirmation first.
///
/// The check lives natively rather than in Dart because `windowShouldClose`
/// must answer synchronously — there is no opportunity to await a round trip
/// once the window is already closing. Dart therefore pushes the state
/// whenever it changes, and the native side reads its own copy.
///
/// A no-op on platforms without the channel (Android, and tests).
class WindowGuard {
  static const _channel = MethodChannel('porter/window');

  static bool _lastReported = false;

  /// Reports whether a transfer is currently in progress. Cheap to call
  /// repeatedly: only a change is sent across the channel.
  static Future<void> setTransferInProgress(bool inProgress) async {
    if (inProgress == _lastReported) return;
    _lastReported = inProgress;

    if (defaultTargetPlatform != TargetPlatform.macOS) return;
    try {
      await _channel.invokeMethod<void>(
        'setTransferInProgress',
        {'inProgress': inProgress},
      );
    } on MissingPluginException {
      // Channel not registered (tests, or a platform without the guard).
    } on PlatformException {
      // Never let a cosmetic guard break scanning.
    }
  }

  @visibleForTesting
  static void resetForTest() => _lastReported = false;
}
