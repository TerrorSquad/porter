import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/camera_fps.dart';
import '../models/camera_resolution.dart';

const _kOutputDirectoryKey = 'porter.outputDirectory';
const _kAutoSaveKey = 'porter.autoSave';
const _kCameraResolutionKey = 'porter.cameraResolution';
const _kCameraFpsKey = 'porter.cameraFps';
const _kRelayUrlKey = 'porter.relayUrl';
const _kSelectedCameraIdKey = 'porter.selectedCameraId';

/// Persisted user settings: output directory, camera resolution, frame rate,
/// relay URL, and the selected camera (macOS only).
class SettingsProvider extends ChangeNotifier {
  String? _outputDirectory;
  bool _autoSave = false;
  CameraResolutionPreset _cameraResolution = CameraResolutionPreset.p720;
  CameraFpsPreset _cameraFps = CameraFpsPreset.auto;
  String _relayUrl = '';
  String? _selectedCameraId;
  bool _loaded = false;
  final Completer<void> _readyCompleter = Completer<void>();

  SettingsProvider() {
    _load();
  }

  /// Resolves once the persisted settings have been loaded from disk.
  Future<void> get ready => _readyCompleter.future;

  /// Null means "use the default download location" (~/Downloads).
  String? get outputDirectory => _outputDirectory;

  /// Whether completed transfers are saved automatically without prompting.
  bool get autoSave => _autoSave;

  CameraResolutionPreset get cameraResolution => _cameraResolution;

  CameraFpsPreset get cameraFps => _cameraFps;

  /// Empty string means relaying to a porter-serve instance is disabled.
  String get relayUrl => _relayUrl;

  String? get selectedCameraId => _selectedCameraId;

  bool get loaded => _loaded;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _outputDirectory = prefs.getString(_kOutputDirectoryKey);
    _autoSave = prefs.getBool(_kAutoSaveKey) ?? false;
    _relayUrl = prefs.getString(_kRelayUrlKey) ?? '';
    _selectedCameraId = prefs.getString(_kSelectedCameraIdKey);

    final resolutionName = prefs.getString(_kCameraResolutionKey);
    if (resolutionName != null) {
      _cameraResolution = CameraResolutionPreset.values.firstWhere(
        (preset) => preset.name == resolutionName,
        orElse: () => CameraResolutionPreset.p720,
      );
    }

    final fpsName = prefs.getString(_kCameraFpsKey);
    if (fpsName != null) {
      _cameraFps = CameraFpsPreset.values.firstWhere(
        (preset) => preset.name == fpsName,
        orElse: () => CameraFpsPreset.auto,
      );
    }

    _loaded = true;
    _readyCompleter.complete();
    notifyListeners();
  }

  Future<void> setOutputDirectory(String? path) async {
    _outputDirectory = path;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      await prefs.remove(_kOutputDirectoryKey);
    } else {
      await prefs.setString(_kOutputDirectoryKey, path);
    }
  }

  Future<void> setAutoSave(bool enabled) async {
    _autoSave = enabled;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoSaveKey, enabled);
  }

  Future<void> setCameraResolution(CameraResolutionPreset preset) async {
    _cameraResolution = preset;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCameraResolutionKey, preset.name);
  }

  Future<void> setCameraFps(CameraFpsPreset preset) async {
    _cameraFps = preset;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCameraFpsKey, preset.name);
  }

  Future<void> setRelayUrl(String url) async {
    _relayUrl = url.trim();
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRelayUrlKey, _relayUrl);
  }

  Future<void> setSelectedCameraId(String? id) async {
    _selectedCameraId = id;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_kSelectedCameraIdKey);
    } else {
      await prefs.setString(_kSelectedCameraIdKey, id);
    }
  }
}
