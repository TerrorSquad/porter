/// Camera frame-rate presets offered in Settings. `auto` leaves the frame
/// rate at whatever the selected resolution's format defaults to; the other
/// presets request the closest supported frame rate from the camera.
enum CameraFpsPreset {
  auto,
  fps15,
  fps24,
  fps30,
  fps60,
}

extension CameraFpsPresetX on CameraFpsPreset {
  /// The requested frame rate, or null for `auto` (no override).
  int? get fps {
    switch (this) {
      case CameraFpsPreset.auto:
        return null;
      case CameraFpsPreset.fps15:
        return 15;
      case CameraFpsPreset.fps24:
        return 24;
      case CameraFpsPreset.fps30:
        return 30;
      case CameraFpsPreset.fps60:
        return 60;
    }
  }

  String get label {
    switch (this) {
      case CameraFpsPreset.auto:
        return 'Auto';
      case CameraFpsPreset.fps15:
        return '15 fps';
      case CameraFpsPreset.fps24:
        return '24 fps';
      case CameraFpsPreset.fps30:
        return '30 fps';
      case CameraFpsPreset.fps60:
        return '60 fps';
    }
  }
}
