import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../providers/scanner_provider.dart';
import '../providers/settings_provider.dart';
import 'settings_screen.dart';

class ScanningScreen extends StatefulWidget {
  const ScanningScreen({Key? key}) : super(key: key);

  @override
  State<ScanningScreen> createState() => _ScanningScreenState();
}

class _ScanningScreenState extends State<ScanningScreen> {
  late MobileScannerController controller;
  List<Map<String, String>> _availableCameras = [];
  String? _activeCameraId;
  bool _ready = false;
  bool _restarting = false;

  @override
  void initState() {
    super.initState();
    controller = MobileScannerController(autoStart: false);
    _initCamera();
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

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _handleQRDetected(BarcodeCapture capture) {
    final provider = context.read<ScannerProvider>();
    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null) {
        provider.ingestQR(rawValue);

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

    if (_ready &&
        !_restarting &&
        defaultTargetPlatform == TargetPlatform.macOS &&
        settings.selectedCameraId != _activeCameraId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _applyCameraChange(settings.selectedCameraId);
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Porter Receiver'),
        centerTitle: true,
        actions: [
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
                      Text(
                        'Total scanned: ${provider.totalScanned} | Duplicates: ${provider.duplicatesSkipped}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ] else ...[
                      Text(
                        'Point camera at QR codes',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
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
