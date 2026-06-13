import 'dart:ui';

/// Camera resolution presets offered in Settings, matching the options
/// previously available in the web receiver's resolution selector.
enum CameraResolutionPreset {
  p480,
  p720,
  p1080,
  p4k,
  square720,
  square1080,
}

extension CameraResolutionPresetX on CameraResolutionPreset {
  Size get size {
    switch (this) {
      case CameraResolutionPreset.p480:
        return const Size(640, 480);
      case CameraResolutionPreset.p720:
        return const Size(1280, 720);
      case CameraResolutionPreset.p1080:
        return const Size(1920, 1080);
      case CameraResolutionPreset.p4k:
        return const Size(3840, 2160);
      case CameraResolutionPreset.square720:
        return const Size(720, 720);
      case CameraResolutionPreset.square1080:
        return const Size(1080, 1080);
    }
  }

  String get label {
    switch (this) {
      case CameraResolutionPreset.p480:
        return '480p (640×480)';
      case CameraResolutionPreset.p720:
        return '720p (1280×720)';
      case CameraResolutionPreset.p1080:
        return '1080p (1920×1080)';
      case CameraResolutionPreset.p4k:
        return '4K (3840×2160)';
      case CameraResolutionPreset.square720:
        return 'Square (720×720)';
      case CameraResolutionPreset.square1080:
        return 'Square (1080×1080)';
    }
  }
}
