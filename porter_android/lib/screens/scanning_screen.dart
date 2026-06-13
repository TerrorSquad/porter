import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../models/camera_fps.dart';
import '../models/camera_resolution.dart';
import '../models/transfer.dart';
import '../providers/scanner_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/format.dart';
import '../utils/transfer_actions.dart';
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
  CameraFpsPreset _activeFps = CameraFpsPreset.auto;
  bool _ready = false;
  bool _restarting = false;
  Timer? _rateTimer;
  DateTime? _lastFlashAt;
  Offset? _focusPoint;
  Timer? _focusIndicatorTimer;

  @override
  void initState() {
    super.initState();
    controller = MobileScannerController(
      autoStart: false,
      cameraResolution: _activeResolution.size,
      cameraFps: _activeFps.fps,
      // The default (DetectionSpeed.normal) imposes a 250ms gap between
      // scans, capping throughput at ~4/s regardless of camera speed.
      // noDuplicates removes that artificial gate and scans as fast as
      // the camera/Vision pipeline allows.
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
    _initCamera();

    // Refresh periodically so the scans/sec readout decays toward 0 between
    // scans, not just when a new one comes in.
    _rateTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });

    context.read<ScannerProvider>().onTransferComplete = _handleTransferComplete;
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

    if (settings.cameraResolution != _activeResolution ||
        settings.cameraFps != _activeFps) {
      await _applyCameraConfigChange(settings.cameraResolution, settings.cameraFps);
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

  /// Recreates the scanner controller with the resolution and frame rate
  /// selected in Settings. Both are constructor-only fields, so the
  /// controller must be disposed and replaced rather than just stopped and
  /// restarted.
  Future<void> _applyCameraConfigChange(
    CameraResolutionPreset resolution,
    CameraFpsPreset fps,
  ) async {
    if (_restarting) return;
    _restarting = true;

    final old = controller;
    final next = MobileScannerController(
      autoStart: false,
      cameraResolution: resolution.size,
      cameraFps: fps.fps,
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
    next.cameraId = _activeCameraId;

    _activeResolution = resolution;
    _activeFps = fps;
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
    _focusIndicatorTimer?.cancel();
    context.read<ScannerProvider>().onTransferComplete = null;
    controller.dispose();
    super.dispose();
  }

  /// Shows a save prompt when a transfer finishes, or saves it automatically
  /// if the auto-save setting is enabled.
  void _handleTransferComplete(Transfer t) {
    if (!mounted) return;

    if (context.read<SettingsProvider>().autoSave) {
      saveTransfer(context, t);
      return;
    }

    final shortId = t.id.length > 8 ? t.id.substring(0, 8) : t.id;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Transfer $shortId complete'),
        action: SnackBarAction(
          label: 'Save',
          onPressed: () => saveTransfer(context, t),
        ),
      ),
    );
  }

  /// Sets the camera focus point at the tap location and shows a brief
  /// reticle there so the focus control is visible on the preview.
  void _handleFocusTap(TapUpDetails details, Size previewSize) {
    final local = details.localPosition;
    final relative = Offset(
      (local.dx / previewSize.width).clamp(0.0, 1.0),
      (local.dy / previewSize.height).clamp(0.0, 1.0),
    );

    setState(() => _focusPoint = local);
    _focusIndicatorTimer?.cancel();
    _focusIndicatorTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _focusPoint = null);
    });

    // Ignore focus errors during a camera restart (e.g. resolution/fps change).
    controller.setFocusPoint(relative).catchError((_) {});
  }

  /// The camera preview with tap-to-focus and a focus reticle overlay.
  Widget _buildPreview() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _handleFocusTap(details, size),
          child: Stack(
            fit: StackFit.expand,
            children: [
              MobileScanner(
                key: ValueKey(controller),
                controller: controller,
                onDetect: _handleQRDetected,
              ),
              if (_focusPoint != null)
                Positioned(
                  left: _focusPoint!.dx - 32,
                  top: _focusPoint!.dy - 32,
                  child: const _FocusReticle(),
                ),
              Positioned(
                left: 24,
                right: 24,
                bottom: 16,
                child: _buildZoomSlider(),
              ),
            ],
          ),
        );
      },
    );
  }

  /// A slider for adjusting the camera's zoom, useful for distant or small
  /// QR codes.
  Widget _buildZoomSlider() {
    return ValueListenableBuilder<MobileScannerState>(
      valueListenable: controller,
      builder: (context, state, child) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              const Icon(Icons.zoom_out, color: Colors.white70, size: 18),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  ),
                  child: Slider(
                    value: state.zoomScale,
                    onChanged: controller.setZoomScale,
                  ),
                ),
              ),
              const Icon(Icons.zoom_in, color: Colors.white70, size: 18),
            ],
          ),
        );
      },
    );
  }

  String _hudText(ScannerProvider provider) {
    final scanned = provider.totalScanned + provider.duplicatesSkipped;
    final rate = provider.scansPerSecond;
    final bytesRate = provider.bytesPerSecond;
    return 'scanned $scanned · new ${provider.totalScanned} · dupes ${provider.duplicatesSkipped} · '
        '${rate.toStringAsFixed(1)}/s · ${formatBytes(bytesRate.round())}/s';
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

        // Flash feedback, throttled so it doesn't fight the torch hardware
        // (and the camera pipeline) at high scan rates.
        final now = DateTime.now();
        if (_lastFlashAt == null ||
            now.difference(_lastFlashAt!) > const Duration(milliseconds: 300)) {
          _lastFlashAt = now;
          // Ignore torch errors if a detection fires before/during controller
          // (re)initialization (e.g. right after start() or a camera switch).
          controller.toggleTorch().catchError((_) {});
          Future.delayed(const Duration(milliseconds: 100), () {
            if (mounted) controller.toggleTorch().catchError((_) {});
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    if (_ready && !_restarting) {
      if (settings.cameraResolution != _activeResolution ||
          settings.cameraFps != _activeFps) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _applyCameraConfigChange(settings.cameraResolution, settings.cameraFps);
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
                child: _activeResolution.isSquare
                    ? Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: _buildPreview(),
                        ),
                      )
                    : _buildPreview(),
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

/// A brief, fading reticle shown where the user tapped to focus.
class _FocusReticle extends StatefulWidget {
  const _FocusReticle();

  @override
  State<_FocusReticle> createState() => _FocusReticleState();
}

class _FocusReticleState extends State<_FocusReticle> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: FadeTransition(
        opacity: Tween<double>(begin: 1, end: 0).animate(_controller),
        child: ScaleTransition(
          scale: Tween<double>(begin: 1.2, end: 1.0).animate(
            CurvedAnimation(parent: _controller, curve: Curves.easeOut),
          ),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.yellow, width: 2),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
    );
  }
}
