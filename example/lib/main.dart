import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugPrint, debugPrintStack, kDebugMode;
import 'package:flutter/material.dart';
import 'package:resumable_downloader/resumable_downloader.dart';

import 'widgets/adaptive_progress_bar.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const DownloadLabPage(),
    );
  }
}

class DownloadLabPage extends StatefulWidget {
  const DownloadLabPage({super.key});

  @override
  State<DownloadLabPage> createState() => _DownloadLabPageState();
}

class _DownloadLabPageState extends State<DownloadLabPage> {
  final DownloadConfiguration _configuration = DownloadConfiguration(
    maxConcurrentDownloads: 3,
    maxConcurrentConnections: 6,
    maxConnectionsPerDownload: 4,
    minimumBytesPerPart: 8 * 1024 * 1024,
    maxRetries: 2,
  );
  final List<_TransferEntry> _entries = <_TransferEntry>[];
  late final DownloadManager _manager = DownloadManager(
    subdirectory: 'transfer_lab',
    configuration: _configuration,
  );
  var _selectedIndex = 0;

  @override
  void dispose() {
    unawaited(_manager.dispose());
    super.dispose();
  }

  void _startRequest(DownloadRequest request, {_TransferEntry? restarting}) {
    final task = _manager.enqueue(request);
    final entry = restarting ?? _TransferEntry(request: request, task: task);
    setState(() {
      if (restarting == null) {
        _entries.insert(0, entry);
      } else {
        entry.task = task;
        entry.update = null;
      }
    });
    task.updates.listen((update) {
      if (!mounted) {
        return;
      }
      setState(() => entry.update = update);
    });
    unawaited(
      task.result.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (kDebugMode) {
            debugPrint('Download failed for ${request.url}: $error');
            debugPrintStack(stackTrace: stackTrace);
          }
        },
      ),
    );
  }

  void _restart(_TransferEntry entry) {
    _startRequest(entry.request, restarting: entry);
  }

  Future<void> _showAddSheet() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AddDownloadSheet(onQueue: _startRequest),
    );
  }

  @override
  Widget build(BuildContext context) {
    final titles = <String>['Transfers', 'Presets', 'Configuration'];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_selectedIndex]),
        actions: [
          if (_selectedIndex == 0)
            IconButton(
              tooltip: 'Add download',
              onPressed: _showAddSheet,
              icon: const Icon(Icons.add),
            ),
        ],
      ),
      body: switch (_selectedIndex) {
        0 => _TransfersView(entries: _entries, onRestart: _restart),
        1 => _PresetsView(onStart: _startRequest),
        _ => _ConfigurationView(configuration: _configuration),
      },
      floatingActionButton:
          _selectedIndex == 0
              ? FloatingActionButton.extended(
                onPressed: _showAddSheet,
                icon: const Icon(Icons.add),
                label: const Text('Add URL'),
              )
              : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected:
            (index) => setState(() => _selectedIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.download_outlined),
            selectedIcon: Icon(Icons.download),
            label: 'Transfers',
          ),
          NavigationDestination(
            icon: Icon(Icons.science_outlined),
            selectedIcon: Icon(Icons.science),
            label: 'Presets',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: 'Configuration',
          ),
        ],
      ),
    );
  }
}

class _AddDownloadSheet extends StatefulWidget {
  const _AddDownloadSheet({required this.onQueue});

  final void Function(DownloadRequest request) onQueue;

  @override
  State<_AddDownloadSheet> createState() => _AddDownloadSheetState();
}

class _AddDownloadSheetState extends State<_AddDownloadSheet> {
  final _urlController = TextEditingController();
  final _fileNameController = TextEditingController();
  String? _urlError;

  @override
  void dispose() {
    _urlController.dispose();
    _fileNameController.dispose();
    super.dispose();
  }

  void _queue() {
    final url = Uri.tryParse(_urlController.text.trim());
    if (url == null || !(url.isScheme('http') || url.isScheme('https'))) {
      setState(() => _urlError = 'Enter a valid HTTP or HTTPS URL.');
      return;
    }
    widget.onQueue(
      DownloadRequest(
        url: url,
        fileName:
            _fileNameController.text.trim().isEmpty
                ? null
                : _fileNameController.text.trim(),
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add download', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              onChanged: (_) {
                if (_urlError != null) {
                  setState(() => _urlError = null);
                }
              },
              decoration: InputDecoration(
                labelText: 'Download URL',
                errorText: _urlError,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _fileNameController,
              decoration: const InputDecoration(
                labelText: 'File name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _queue,
              child: const Text('Queue download'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransfersView extends StatelessWidget {
  const _TransfersView({required this.entries, required this.onRestart});

  final List<_TransferEntry> entries;
  final void Function(_TransferEntry entry) onRestart;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(
        child: Text(
          'Add a URL or start a preset to inspect transfer behavior.',
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder:
          (context, index) =>
              _TransferTile(entry: entries[index], onRestart: onRestart),
    );
  }
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({required this.entry, required this.onRestart});

  final _TransferEntry entry;
  final void Function(_TransferEntry entry) onRestart;

  @override
  Widget build(BuildContext context) {
    final update = entry.update;
    final state = update?.status ?? DownloadStatus.queued;
    final pathSegments = entry.request.url.pathSegments;
    final fileName =
        entry.request.fileName ??
        (pathSegments.isEmpty ? entry.request.url.host : pathSegments.last);
    final ranges = update?.ranges ?? const <DownloadRangeUpdate>[];
    final canRestart =
        state == DownloadStatus.failed || state == DownloadStatus.cancelled;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                _StatusLabel(status: state),
              ],
            ),
            const SizedBox(height: 8),
            AdaptiveProgressBar(ranges: ranges),
            const SizedBox(height: 8),
            if (state == DownloadStatus.failed && update?.error != null) ...[
              Text(
                update!.error.toString(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${update?.receivedBytes ?? 0} bytes'
                    '${update?.totalBytes == null ? '' : ' / ${update!.totalBytes}'}'
                    '${ranges.length > 1 ? ' · ${ranges.length} parts' : ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (state == DownloadStatus.downloading ||
                    state == DownloadStatus.preparing ||
                    state == DownloadStatus.retrying)
                  TextButton(
                    onPressed: () => unawaited(entry.task.cancel()),
                    child: const Text('Cancel'),
                  )
                else if (canRestart)
                  IconButton(
                    tooltip: 'Restart transfer',
                    onPressed: () => onRestart(entry),
                    icon: const Icon(Icons.refresh),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.status});

  final DownloadStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      DownloadStatus.completed => Colors.green,
      DownloadStatus.failed => Theme.of(context).colorScheme.error,
      DownloadStatus.retrying => Colors.orange,
      DownloadStatus.cancelled => Colors.grey,
      _ => Theme.of(context).colorScheme.primary,
    };
    return Text(
      status.name,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
    );
  }
}

class _PresetsView extends StatelessWidget {
  const _PresetsView({required this.onStart});

  final void Function(DownloadRequest request) onStart;

  static final List<_Preset> _presets = <_Preset>[
    _Preset(
      name: 'Multipart fixture',
      description:
          'Use a large Range-enabled file to inspect segmented progress.',
      url: Uri.parse('https://proof.ovh.net/files/100Mb.dat'),
      fileName: 'multipart-fixture.bin',
    ),
    _Preset(
      name: 'Single-stream fixture',
      description: 'Use a small file or a server without Range support.',
      url: Uri.parse('https://proof.ovh.net/files/1Mb.dat'),
      fileName: 'single-fixture.bin',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _presets.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final preset = _presets[index];
        return ListTile(
          tileColor: Theme.of(context).colorScheme.surfaceContainerLow,
          title: Text(preset.name),
          subtitle: Text(preset.description),
          trailing: FilledButton(
            onPressed:
                () => onStart(
                  DownloadRequest(url: preset.url, fileName: preset.fileName),
                ),
            child: const Text('Start'),
          ),
        );
      },
    );
  }
}

class _ConfigurationView extends StatelessWidget {
  const _ConfigurationView({required this.configuration});

  final DownloadConfiguration configuration;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Manager limits', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          title: const Text('Active files'),
          trailing: Text('${configuration.maxConcurrentDownloads}'),
        ),
        ListTile(
          title: const Text('Global connections'),
          trailing: Text('${configuration.maxConcurrentConnections}'),
        ),
        ListTile(
          title: const Text('Connections per file'),
          trailing: Text('${configuration.maxConnectionsPerDownload}'),
        ),
        ListTile(
          title: const Text('Minimum part size'),
          trailing: Text(
            '${configuration.minimumBytesPerPart ~/ (1024 * 1024)} MB',
          ),
        ),
      ],
    );
  }
}

class _TransferEntry {
  _TransferEntry({required this.request, required this.task});

  final DownloadRequest request;
  DownloadTask task;
  DownloadUpdate? update;
}

class _Preset {
  const _Preset({
    required this.name,
    required this.description,
    required this.url,
    required this.fileName,
  });

  final String name;
  final String description;
  final Uri url;
  final String fileName;
}
