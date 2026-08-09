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
import '../services/window_guard.dart';
import '../utils/format.dart';
import '../utils/transfer_actions.dart';
import 'settings_screen.dart';
import 'transfers_screen.dart';

class ScanningScreen extends StatefulWidget {
  const ScanningScreen({super.key});

  @override
  State<ScanningScreen> createState() => _ScanningScreenState();
}

class _ScanningScreenState extends State<ScanningScreen> with WidgetsBindingObserver {
  late MobileScannerController controller;
  List<Map<String, String>> _availableCameras = [];
  String? _activeCameraId;
  CameraResolutionPreset _activeResolution = CameraResolutionPreset.p1080;
  CameraFpsPreset _activeFps = CameraFpsPreset.auto;
  bool _ready = false;
  bool _restarting = false;
  late final ScannerProvider _scannerProvider;
  Timer? _rateTimer;
  Offset? _focusPoint;
  Timer? _focusIndicatorTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = MobileScannerController(
      autoStart: false,
      cameraResolution: _activeResolution.size,
      cameraFps: _activeFps.fps,
      // The default (DetectionSpeed.normal) imposes a 250ms gap between
      // scans, capping throughput at ~4/s regardless of camera speed.
      // noDuplicates removes that artificial gate and scans as fast as
      // the camera/Vision pipeline allows.
      detectionSpeed: DetectionSpeed.noDuplicates,
      // Porter only ever emits QR codes. Restricting the symbology set
      // narrows the native decode request (Vision/ML Kit) to just QR
      // instead of scanning for every supported barcode format each frame.
      formats: const [BarcodeFormat.qrCode],
    );
    _initCamera();

    // Refresh periodically so the scans/sec readout decays toward 0 between
    // scans, not just when a new one comes in.
    _rateTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() {});

      // Keep the native close guard in step with reality. A transfer counts
      // as in progress when it has started, hasn't completed, and the worker
      // is still alive -- quitting past a dead worker costs nothing.
      final scanner = context.read<ScannerProvider>();
      final settings = context.read<SettingsProvider>();
      final active = scanner.activeTransfer;
      final inProgress = settings.confirmExitDuringTransfer &&
          active != null &&
          !active.isComplete &&
          !scanner.workerDead;
      unawaited(WindowGuard.setTransferInProgress(inProgress));
    });

    _scannerProvider = context.read<ScannerProvider>();
    _scannerProvider.onTransferComplete = _handleTransferComplete;
  }

  Future<void> _initCamera() async {
    final settings = context.read<SettingsProvider>();
    final scanner = context.read<ScannerProvider>();
    await settings.ready;

    unawaited(scanner.hydrateFromDisk(settings.outputDirectory));

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
      formats: const [BarcodeFormat.qrCode],
    );
    next.cameraId = _activeCameraId;

    _activeResolution = resolution;
    _activeFps = fps;
    if (mounted) {
      setState(() {
        controller = next;
      });
      // Wait for the rebuilt MobileScanner widget to attach to `next`,
      // otherwise controller.start() below races that attach and can
      // time out with a controllerNotAttached error.
      await WidgetsBinding.instance.endOfFrame;
    } else {
      controller = next;
    }

    old.dispose();
    await controller.start();

    _restarting = false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rateTimer?.cancel();
    _focusIndicatorTimer?.cancel();
    _scannerProvider.onTransferComplete = null;
    controller.dispose();
    super.dispose();
  }

  /// Forces a metadata flush when the app is backgrounded, killed, or
  /// otherwise loses foreground focus, so in-flight progress isn't lost
  /// beyond the debounce window (see ChunkMetadataWriter).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _scannerProvider.flushAll();
    }
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

  /// A `--speed` value (seconds per frame) the sender could move to, from the
  /// receiver's measured decode rate. Rounded to something typeable and
  /// clamped so it never suggests a pace the camera cannot follow.
  static String? _suggestedSpeed(double decodesPerSecond) {
    if (decodesPerSecond < 2) return null;
    final seconds = (1 / decodesPerSecond).clamp(0.05, 0.5);
    return seconds.toStringAsFixed(2);
  }

  String _hudText(ScannerProvider provider) {
    final scanned = provider.totalScanned + provider.duplicatesSkipped;
    final rate = provider.scansPerSecond;
    final bytesRate = provider.bytesPerSecond;
    final senderMs = provider.estimatedSenderIntervalMs;
    // `rate` is the receiver's raw decode-attempt rate (duplicates and all —
    // dominated by how many times each still-displayed frame gets re-decoded
    // before the sender advances). `senderMs` estimates the sender's actual
    // frame interval from new-chunk arrival gaps, so it's the number that
    // actually answers "could the sender go faster?".
    final senderPart = senderMs != null ? ' · sender ~${senderMs}ms/frame' : '';
    // Naming the flag beats hinting at it: the difference between the
    // sender's current pace and one the receiver can keep up with is worth
    // hours on a large transfer, and the user has to guess the value
    // otherwise. Target roughly the receiver's own decode rate.
    final hintPart = switch (provider.speedHint) {
      SpeedHint.increase => ' · could go faster ⚡'
          '${_suggestedSpeed(rate) != null ? ' (try --speed=${_suggestedSpeed(rate)})' : ''}',
      SpeedHint.decrease => ' · try slowing down ⚠️',
      null => '',
    };
    return 'scanned $scanned · new ${provider.totalScanned} · dupes ${provider.duplicatesSkipped} · '
        '${rate.toStringAsFixed(1)}/s · ${formatBytes(bytesRate.round())}/s$senderPart$hintPart';
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
    final settings = context.read<SettingsProvider>();
    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null) {
        provider.ingestQR(
          rawValue,
          relayUrl: settings.relayUrl,
          outputDirectory: settings.outputDirectory,
        );
        // No per-scan torch blink: on a phone the torch IS the camera flash
        // LED, so blinking it after every scan strobes the user, fights the
        // manual Flash toggle, and is relentless at high scan rates (fountain).
        // The live progress counter is the scan feedback.
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
                    // A stalled or dead worker is otherwise invisible: the
                    // camera and FPS readout run on the main isolate and keep
                    // updating regardless, so the app looks busy while
                    // nothing is being ingested.
                    if (provider.isStalled) ...[
                      _StallBanner(
                        dead: provider.workerDead,
                        since: provider.sinceLastNewChunk,
                        error: provider.workerError,
                      ),
                      const SizedBox(height: 12),
                    ],

                    // Progress
                    if (transfer != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Stack(
                          children: [
                            // Symbol collection, drawn behind. Before the
                            // peeling avalanche blocks sit near zero for a
                            // long time, so this is what shows the transfer
                            // is alive; it is dimmer because it is progress
                            // toward decoding, not decoded data.
                            LinearProgressIndicator(
                              value: transfer.collectionProgress,
                              minHeight: 8,
                              // The default track is a translucent tint of
                              // the fill colour, which on the dark chrome
                              // left a nearly empty bar looking nearly full.
                              backgroundColor: Colors.white12,
                              valueColor: AlwaysStoppedAnimation(
                                Colors.greenAccent.shade400
                                    .withValues(alpha: 0.28),
                              ),
                            ),
                            // Blocks actually recovered. Denominator is K, so
                            // it never moves and 100% means done.
                            LinearProgressIndicator(
                              value: transfer.displayProgress,
                              minHeight: 8,
                              backgroundColor: Colors.transparent,
                              valueColor: AlwaysStoppedAnimation(
                                Colors.greenAccent.shade400,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        transfer.progressLabel,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (transfer.isFountain && !transfer.isComplete) ...[
                        const SizedBox(height: 4),
                        Text(
                          fountainHint(
                            symbols: transfer.fountainSymbols,
                            symbolsNeeded: transfer.fountainSymbolsNeeded,
                            blocks: transfer.seenIndices.length,
                            totalBlocks: transfer.total,
                            newPerSecond: provider.newPerSecond,
                          ),
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: Colors.white54),
                        ),
                      ],
                      const SizedBox(height: 8),
                      _buildHud(context, provider, settings),
                      const SizedBox(height: 4),
                      // A configured path that doesn't exist resolves silently
                      // to the default, and the transfer starts from block 1
                      // with no visible cause. Showing where bytes are landing
                      // makes that mistake self-evident.
                      Text(
                        'saving to ${settings.outputDirectory ?? 'default downloads folder'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: Colors.white38),
                      ),
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

/// Shown when nothing new has been decoded for a while, or the worker died.
class _StallBanner extends StatelessWidget {
  const _StallBanner({required this.dead, required this.since, this.error});

  final bool dead;
  final Duration? since;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colour = dead ? Colors.redAccent : Colors.amberAccent;
    final headline = dead
        ? 'Decoding stopped — restart the app to resume'
        : 'No new frames for ${formatDuration(since ?? Duration.zero)}';
    final detail = dead
        ? 'Blocks already received are saved and will be picked up on restart.'
        : 'Check the sender is still advancing and the code is in frame.';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        border: Border.all(color: colour.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(dead ? Icons.error_outline : Icons.warning_amber_rounded,
                  size: 18, color: colour),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  headline,
                  style: TextStyle(color: colour, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(detail,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.white70)),
          if (error != null) ...[
            const SizedBox(height: 4),
            Text(error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.white38)),
          ],
        ],
      ),
    );
  }
}
