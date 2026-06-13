import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../models/camera_resolution.dart';
import '../providers/scanner_provider.dart';
import '../providers/settings_provider.dart';
import 'settings_screen.dart';
import 'transfers_screen.dart';

class ScanningScreen extends StatefulWidget {
  const ScanningScreen({Key? key}) : super(key: key);

  @override
  State<ScanningScreen> createState() => _ScanningScreenState();
}

class _ScanningScreenState extends State<ScanningScreen> {
  late MobileScannerController controller;
  List<Map<String, String>> _availableCameras = [];
  String? _activeCameraId;
  CameraResolutionPreset _activeResolution = CameraResolutionPreset.p720;
  bool _ready = false;
  bool _restarting = false;
  Timer? _rateTimer;

  @override
  void initState() {
    super.initState();
    controller = MobileScannerController(
      autoStart: false,
      cameraResolution: _activeResolution.size,
    );
    _initCamera();

    // Refresh periodically so the scans/sec readout decays toward 0 between
    // scans, not just when a new one comes in.
    _rateTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _initCamera() async {
    final settings = context.read<SettingsProvider>();
    await settings.ready;

    if (defaultTargetPlatform == TargetPlatform.macOS) {
      final cameras = await controller.getAvailableCameras();
      final savedId = settings.selectedCameraId;

      String? selectedId;
      if (savedId != null && cameras.any((camera) => camera['id'] == savedId)) {
        selectedId = savedId;
      } else if (cameras.isNotEmpty) {
        selectedId = cameras.first['id'];
      }

      if (selectedId != settings.selectedCameraId) {
        await settings.setSelectedCameraId(selectedId);
      }

      _activeCameraId = selectedId;
      controller.cameraId = selectedId;

      if (mounted) {
        setState(() {
          _availableCameras = cameras;
        });
      }
    }

    _ready = true;

    if (settings.cameraResolution != _activeResolution) {
      await _applyResolutionChange(settings.cameraResolution);
      return;
    }

    await controller.start();
  }

  /// Restarts the scanner on the camera selected in Settings.
  Future<void> _applyCameraChange(String? cameraId) async {
    if (_restarting) return;
    _restarting = true;

    _activeCameraId = cameraId;
    controller.cameraId = cameraId;

    await controller.stop();
    await controller.start();

    _restarting = false;
  }

  /// Recreates the scanner controller with the resolution selected in
  /// Settings. The resolution is a constructor-only field, so the controller
  /// must be disposed and replaced rather than just stopped and restarted.
  Future<void> _applyResolutionChange(CameraResolutionPreset resolution) async {
    if (_restarting) return;
    _restarting = true;

    final old = controller;
    final next = MobileScannerController(
      autoStart: false,
      cameraResolution: resolution.size,
    );
    next.cameraId = _activeCameraId;

    _activeResolution = resolution;
    if (mounted) {
      setState(() {
        controller = next;
      });
    } else {
      controller = next;
    }

    old.dispose();
    await controller.start();

    _restarting = false;
  }

  @override
  void dispose() {
    _rateTimer?.cancel();
    controller.dispose();
    super.dispose();
  }

  String _hudText(ScannerProvider provider) {
    final scanned = provider.totalScanned + provider.duplicatesSkipped;
    final rate = provider.scansPerSecond;
    return 'scanned $scanned · new ${provider.totalScanned} · dupes ${provider.duplicatesSkipped} · ${rate.toStringAsFixed(1)}/s';
  }

  Widget _buildHud(BuildContext context, ScannerProvider provider, SettingsProvider settings) {
    final text = Text(_hudText(provider), style: Theme.of(context).textTheme.labelSmall);
    if (settings.relayUrl.isEmpty) return text;

    final Color dotColor;
    if (provider.relayLastOk == true) {
      dotColor = Colors.green;
    } else if (provider.relayLastOk == false) {
      dotColor = Colors.red;
    } else {
      dotColor = Colors.grey;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        text,
        const SizedBox(width: 8),
        Text('●', style: TextStyle(color: dotColor, fontSize: 12)),
      ],
    );
  }

  void _handleQRDetected(BarcodeCapture capture) {
    final provider = context.read<ScannerProvider>();
    final relayUrl = context.read<SettingsProvider>().relayUrl;
    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null) {
        provider.ingestQR(rawValue, relayUrl: relayUrl);

        // Flash feedback
        controller.toggleTorch();
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) controller.toggleTorch();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    if (_ready && !_restarting) {
      if (settings.cameraResolution != _activeResolution) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _applyResolutionChange(settings.cameraResolution);
        });
      } else if (defaultTargetPlatform == TargetPlatform.macOS &&
          settings.selectedCameraId != _activeCameraId) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _applyCameraChange(settings.selectedCameraId);
        });
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Porter Receiver'),
        centerTitle: true,
        actions: [
          Consumer<ScannerProvider>(
            builder: (context, provider, _) => IconButton(
              icon: Badge(
                label: Text('${provider.allTransfers.length}'),
                isLabelVisible: provider.allTransfers.isNotEmpty,
                child: const Icon(Icons.list_alt),
              ),
              tooltip: 'Transfers',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const TransfersScreen()),
                );
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      SettingsScreen(availableCameras: _availableCameras),
                ),
              );
            },
          ),
        ],
      ),
      body: Consumer<ScannerProvider>(
        builder: (context, provider, _) {
          final transfer = provider.activeTransfer;

          return Column(
            children: [
              Expanded(
                child: MobileScanner(
                  key: ValueKey(controller),
                  controller: controller,
                  onDetect: _handleQRDetected,
                ),
              ),
              Container(
                color: Colors.black87,
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Progress
                    if (transfer != null) ...[
                      LinearProgressIndicator(
                        value: transfer.progress / 100,
                        minHeight: 8,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${transfer.seenIndices.length} / ${transfer.total} chunks',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      _buildHud(context, provider, settings),
                    ] else ...[
                      Text(
                        'Point camera at QR codes',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 8),
                      _buildHud(context, provider, settings),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton.icon(
                          onPressed: controller.toggleTorch,
                          icon: const Icon(Icons.flash_on),
                          label: const Text('Flash'),
                        ),
                        if (transfer != null)
                          ElevatedButton.icon(
                            onPressed: () => provider.resetAll(),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Reset'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red.shade700,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
