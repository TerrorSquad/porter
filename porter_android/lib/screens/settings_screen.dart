import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/camera_resolution.dart';
import '../providers/settings_provider.dart';

class SettingsScreen extends StatefulWidget {
  final List<Map<String, String>> availableCameras;

  const SettingsScreen({Key? key, this.availableCameras = const []})
      : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _defaultDownloadsPath;
  late final TextEditingController _relayController;

  @override
  void initState() {
    super.initState();
    _relayController =
        TextEditingController(text: context.read<SettingsProvider>().relayUrl);
    _loadDefaultDownloadsPath();
  }

  Future<void> _loadDefaultDownloadsPath() async {
    final dir = await getDownloadsDirectory();
    if (mounted) {
      setState(() {
        _defaultDownloadsPath = dir?.path;
      });
    }
  }

  @override
  void dispose() {
    _relayController.dispose();
    super.dispose();
  }

  Future<void> _pickOutputDirectory() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path != null && mounted) {
      await context.read<SettingsProvider>().setOutputDirectory(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final outputDir =
        settings.outputDirectory ?? _defaultDownloadsPath ?? '~/Downloads';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader('Output Directory'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(outputDir, style: Theme.of(context).textTheme.bodyMedium),
                  if (settings.outputDirectory == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Default (saved to ~/Downloads)',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: Colors.white54),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _pickOutputDirectory,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Change'),
                      ),
                      const SizedBox(width: 8),
                      if (settings.outputDirectory != null)
                        TextButton(
                          onPressed: () => context
                              .read<SettingsProvider>()
                              .setOutputDirectory(null),
                          child: const Text('Reset to default'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const _SectionHeader('Camera Resolution'),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<CameraResolutionPreset>(
                  value: settings.cameraResolution,
                  isExpanded: true,
                  dropdownColor: Theme.of(context).cardColor,
                  onChanged: (preset) {
                    if (preset != null) {
                      context.read<SettingsProvider>().setCameraResolution(preset);
                    }
                  },
                  items: CameraResolutionPreset.values
                      .map(
                        (preset) => DropdownMenuItem(
                          value: preset,
                          child: Text(preset.label),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ),
          if (defaultTargetPlatform == TargetPlatform.macOS &&
              widget.availableCameras.length > 1) ...[
            const SizedBox(height: 24),
            const _SectionHeader('Camera'),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: settings.selectedCameraId,
                    isExpanded: true,
                    dropdownColor: Theme.of(context).cardColor,
                    onChanged: (id) {
                      if (id != null) {
                        context.read<SettingsProvider>().setSelectedCameraId(id);
                      }
                    },
                    items: widget.availableCameras
                        .map(
                          (camera) => DropdownMenuItem(
                            value: camera['id'],
                            child: Text(camera['label'] ?? camera['id'] ?? ''),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          const _SectionHeader('Relay to porter serve'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _relayController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Server URL',
                      hintText: 'http://192.168.1.10:8080',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) =>
                        context.read<SettingsProvider>().setRelayUrl(value),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Leave empty to disable. Each scanned QR code will be '
                    'POSTed to <url>/upload, e.g. a "porter serve" instance.',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Colors.white54),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Colors.green.shade400,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
