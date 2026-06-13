import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:porter_receiver/models/camera_fps.dart';
import 'package:porter_receiver/models/camera_resolution.dart';
import 'package:porter_receiver/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults before any settings are saved', () async {
      final settings = SettingsProvider();
      await settings.ready;

      expect(settings.outputDirectory, null);
      expect(settings.cameraResolution, CameraResolutionPreset.p720);
      expect(settings.cameraFps, CameraFpsPreset.auto);
      expect(settings.relayUrl, '');
      expect(settings.autoSave, false);
      expect(settings.selectedCameraId, null);
      expect(settings.loaded, true);
    });

    test('setOutputDirectory persists and notifies, null clears it', () async {
      final settings = SettingsProvider();
      await settings.ready;

      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.setOutputDirectory('/tmp/porter');
      expect(settings.outputDirectory, '/tmp/porter');
      expect(notifications, greaterThan(0));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('porter.outputDirectory'), '/tmp/porter');

      await settings.setOutputDirectory(null);
      expect(settings.outputDirectory, null);
      expect(prefs.containsKey('porter.outputDirectory'), false);
    });

    test('setRelayUrl trims whitespace and persists', () async {
      final settings = SettingsProvider();
      await settings.ready;

      var notified = false;
      settings.addListener(() => notified = true);

      await settings.setRelayUrl('  http://192.168.1.5:8080  ');
      expect(settings.relayUrl, 'http://192.168.1.5:8080');
      expect(notified, true);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('porter.relayUrl'), 'http://192.168.1.5:8080');
    });

    test('setAutoSave persists and notifies', () async {
      final settings = SettingsProvider();
      await settings.ready;

      var notified = false;
      settings.addListener(() => notified = true);

      await settings.setAutoSave(true);
      expect(settings.autoSave, true);
      expect(notified, true);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('porter.autoSave'), true);
    });

    test('setCameraResolution and setCameraFps persist independently', () async {
      final settings = SettingsProvider();
      await settings.ready;

      await settings.setCameraResolution(CameraResolutionPreset.p1080);
      expect(settings.cameraResolution, CameraResolutionPreset.p1080);

      await settings.setCameraFps(CameraFpsPreset.fps30);
      expect(settings.cameraFps, CameraFpsPreset.fps30);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('porter.cameraResolution'), 'p1080');
      expect(prefs.getString('porter.cameraFps'), 'fps30');
    });

    test('setSelectedCameraId persists and null clears it', () async {
      final settings = SettingsProvider();
      await settings.ready;

      await settings.setSelectedCameraId('camera-1');
      expect(settings.selectedCameraId, 'camera-1');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('porter.selectedCameraId'), 'camera-1');

      await settings.setSelectedCameraId(null);
      expect(settings.selectedCameraId, null);
      expect(prefs.containsKey('porter.selectedCameraId'), false);
    });

    test('switching to a resolution that drops the current fps adjusts it', () async {
      final settings = SettingsProvider();
      await settings.ready;

      await settings.setCameraFps(CameraFpsPreset.fps60);
      expect(settings.cameraFps, CameraFpsPreset.fps60);

      // p4k caps at 30fps, so fps60 is no longer supported and gets dropped
      // to the resolution's highest supported preset (fps30).
      await settings.setCameraResolution(CameraResolutionPreset.p4k);
      expect(settings.cameraResolution, CameraResolutionPreset.p4k);
      expect(settings.cameraFps, CameraFpsPreset.fps30);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('porter.cameraFps'), 'fps30');
    });
  });
}
