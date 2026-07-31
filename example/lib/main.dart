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
  DownloadConfiguration _configuration = DownloadConfiguration(
    maxConcurrentDownloads: 3,
    maxConcurrentConnections: 6,
    maxConnectionsPerDownload: 4,
    minimumBytesPerPart: 8 * 1024 * 1024,
    maxRetries: 2,
  );
  final List<_TransferEntry> _entries = <_TransferEntry>[];
  late DownloadManager _manager;
  var _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _manager = _createManager();
    unawaited(_restorePending());
  }

  @override
  void dispose() {
    unawaited(_manager.dispose());
    super.dispose();
  }

  void _startRequest(DownloadRequest request, {_TransferEntry? restarting}) {
    _trackTask(request, _manager.enqueue(request), restarting: restarting);
  }

  void _trackTask(
    DownloadRequest request,
    DownloadTask task, {
    _TransferEntry? restarting,
  }) {
    final entry = restarting ?? _TransferEntry(request: request, task: task);
    setState(() {
      if (restarting == null) {
        _entries.insert(0, entry);
      } else {
        entry.request = request;
        entry.task = task;
        entry.update = null;
        entry.resetTelemetry();
      }
    });
    task.updates.listen((update) {
      if (!mounted) {
        return;
      }
      setState(() {
        entry.record(update);
        entry.update = update;
      });
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

  Future<void> _restorePending() async {
    final restoredRequests = <DownloadRequest>[];
    try {
      final tasks = await _manager.restorePending((pending) async {
        final request = DownloadRequest(
          url: pending.sourceUri,
          fileName: pending.fileName,
          restorationId: pending.restorationId,
          expectedSha256: pending.expectedSha256,
        );
        restoredRequests.add(request);
        return request;
      });
      if (!mounted) {
        return;
      }
      for (var index = 0; index < tasks.length; index++) {
        _trackTask(restoredRequests[index], tasks[index]);
      }
    } on Object catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Could not restore pending downloads: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  void _restart(_TransferEntry entry) {
    final request = entry.request;
    _startRequest(
      DownloadRequest(
        url: request.url,
        fileName: request.fileName,
        subdirectory: request.subdirectory,
        headers: request.headers,
        expectedSha256: request.expectedSha256,
        existingFilePolicy: ExistingFilePolicy.replace,
      ),
      restarting: entry,
    );
  }

  DownloadManager _createManager() => DownloadManager(
    subdirectory: 'transfer_lab',
    configuration: _configuration,
  );

  Future<void> _deleteArtifacts(_TransferEntry entry) async {
    try {
      await _manager.deleteArtifacts(
        entry.request,
        cancelActive: !entry.task.isCompleted,
      );
      if (mounted) {
        setState(() => _entries.remove(entry));
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete artifacts: $error')),
        );
      }
    }
  }

  Future<bool> _applyConfiguration(DownloadConfiguration configuration) async {
    if (_entries.any((entry) => !entry.task.isCompleted)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Finish or cancel active transfers first.'),
        ),
      );
      return false;
    }
    await _manager.dispose();
    if (!mounted) {
      return false;
    }
    setState(() {
      _configuration = configuration;
      _manager = _createManager();
    });
    return true;
  }

  Future<void> _showConfigurationSheet() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder:
        (_) => _ConfigurationSheet(
          configuration: _configuration,
          onApply: _applyConfiguration,
        ),
  );

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
        0 => _TransfersView(
          entries: _entries,
          onRestart: _restart,
          onDelete: _deleteArtifacts,
        ),
        1 => _PresetsView(onStart: _startRequest),
        _ => _ConfigurationView(
          configuration: _configuration,
          onEdit: _showConfigurationSheet,
        ),
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
  final _checksumController = TextEditingController();
  String? _urlError;
  var _existingFilePolicy = ExistingFilePolicy.resume;

  @override
  void dispose() {
    _urlController.dispose();
    _fileNameController.dispose();
    _checksumController.dispose();
    super.dispose();
  }

  void _queue() {
    final url = Uri.tryParse(_urlController.text.trim());
    if (url == null || !(url.isScheme('http') || url.isScheme('https'))) {
      setState(() => _urlError = 'Enter a valid HTTP or HTTPS URL.');
      return;
    }
    try {
      widget.onQueue(
        DownloadRequest(
          url: url,
          fileName:
              _fileNameController.text.trim().isEmpty
                  ? null
                  : _fileNameController.text.trim(),
          expectedSha256:
              _checksumController.text.trim().isEmpty
                  ? null
                  : _checksumController.text.trim(),
          existingFilePolicy: _existingFilePolicy,
        ),
      );
    } on ArgumentError catch (error) {
      setState(() => _urlError = error.message?.toString() ?? error.toString());
      return;
    }
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
            const SizedBox(height: 12),
            DropdownButtonFormField<ExistingFilePolicy>(
              initialValue: _existingFilePolicy,
              decoration: const InputDecoration(
                labelText: 'Existing output',
                border: OutlineInputBorder(),
              ),
              items: ExistingFilePolicy.values
                  .map(
                    (policy) => DropdownMenuItem(
                      value: policy,
                      child: Text(policy.name),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (policy) {
                if (policy != null) {
                  setState(() => _existingFilePolicy = policy);
                }
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _checksumController,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Expected SHA-256 (optional)',
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
  const _TransfersView({
    required this.entries,
    required this.onRestart,
    required this.onDelete,
  });

  final List<_TransferEntry> entries;
  final void Function(_TransferEntry entry) onRestart;
  final Future<void> Function(_TransferEntry entry) onDelete;

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
          (context, index) => _TransferTile(
            entry: entries[index],
            onRestart: onRestart,
            onDelete: onDelete,
          ),
    );
  }
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({
    required this.entry,
    required this.onRestart,
    required this.onDelete,
  });

  final _TransferEntry entry;
  final void Function(_TransferEntry entry) onRestart;
  final Future<void> Function(_TransferEntry entry) onDelete;

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
                    '${_formatBytes(update?.receivedBytes ?? 0)}'
                    '${update?.totalBytes == null ? '' : ' / ${_formatBytes(update!.totalBytes!)}'}'
                    '${entry.bytesPerSecond > 0 ? ' · ${_formatSpeed(entry.bytesPerSecond)}' : ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (state == DownloadStatus.downloading ||
                    state == DownloadStatus.preparing ||
                    state == DownloadStatus.retrying)
                  IconButton(
                    tooltip: 'Pause transfer',
                    onPressed: () => unawaited(entry.task.pause()),
                    icon: const Icon(Icons.pause_outlined),
                  )
                else if (state == DownloadStatus.paused)
                  IconButton(
                    tooltip: 'Resume transfer',
                    onPressed: () => unawaited(entry.task.resume()),
                    icon: const Icon(Icons.play_arrow_outlined),
                  ),
                if (state == DownloadStatus.downloading ||
                    state == DownloadStatus.preparing ||
                    state == DownloadStatus.retrying ||
                    state == DownloadStatus.paused ||
                    state == DownloadStatus.validating)
                  IconButton(
                    tooltip: 'Cancel transfer',
                    onPressed: () => unawaited(entry.task.cancel()),
                    icon: const Icon(Icons.close),
                  )
                else if (canRestart || state == DownloadStatus.completed)
                  IconButton(
                    tooltip: 'Run again and replace output',
                    onPressed: () => onRestart(entry),
                    icon: const Icon(Icons.refresh),
                  ),
                IconButton(
                  tooltip:
                      entry.task.isCompleted
                          ? 'Delete output and staged data'
                          : 'Cancel and delete transfer data',
                  onPressed: () => unawaited(onDelete(entry)),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            if (ranges.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '${update?.activeRanges ?? 0} active · '
                '${update?.completedRanges ?? 0}/${ranges.length} parts',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
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
  const _ConfigurationView({required this.configuration, required this.onEdit});

  final DownloadConfiguration configuration;
  final VoidCallback onEdit;

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
        ListTile(
          title: const Text('Checkpoint interval'),
          trailing: Text('${configuration.checkpointBytes ~/ 1024} KB'),
        ),
        ListTile(
          title: const Text('Retry attempts'),
          trailing: Text('${configuration.maxRetries}'),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onEdit,
          icon: const Icon(Icons.tune),
          label: const Text('Edit session settings'),
        ),
      ],
    );
  }
}

class _ConfigurationSheet extends StatefulWidget {
  const _ConfigurationSheet({
    required this.configuration,
    required this.onApply,
  });

  final DownloadConfiguration configuration;
  final Future<bool> Function(DownloadConfiguration configuration) onApply;

  @override
  State<_ConfigurationSheet> createState() => _ConfigurationSheetState();
}

class _ConfigurationSheetState extends State<_ConfigurationSheet> {
  late final TextEditingController _downloadsController;
  late final TextEditingController _connectionsController;
  late final TextEditingController _perFileController;
  late final TextEditingController _partSizeController;
  late final TextEditingController _checkpointController;
  late final TextEditingController _retriesController;
  String? _error;

  @override
  void initState() {
    super.initState();
    final config = widget.configuration;
    _downloadsController = TextEditingController(
      text: '${config.maxConcurrentDownloads}',
    );
    _connectionsController = TextEditingController(
      text: '${config.maxConcurrentConnections}',
    );
    _perFileController = TextEditingController(
      text: '${config.maxConnectionsPerDownload}',
    );
    _partSizeController = TextEditingController(
      text: '${config.minimumBytesPerPart ~/ (1024 * 1024)}',
    );
    _checkpointController = TextEditingController(
      text: '${config.checkpointBytes ~/ 1024}',
    );
    _retriesController = TextEditingController(text: '${config.maxRetries}');
  }

  @override
  void dispose() {
    _downloadsController.dispose();
    _connectionsController.dispose();
    _perFileController.dispose();
    _partSizeController.dispose();
    _checkpointController.dispose();
    _retriesController.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    try {
      final configuration = DownloadConfiguration(
        maxConcurrentDownloads: _parsePositive(_downloadsController, 'files'),
        maxConcurrentConnections: _parsePositive(
          _connectionsController,
          'connections',
        ),
        maxConnectionsPerDownload: _parsePositive(
          _perFileController,
          'per file',
        ),
        minimumBytesPerPart:
            _parsePositive(_partSizeController, 'part size') * 1024 * 1024,
        checkpointBytes:
            _parsePositive(_checkpointController, 'checkpoint') * 1024,
        maxRetries: _parseNonNegative(_retriesController, 'retries'),
        retryDelay: widget.configuration.retryDelay,
      );
      final applied = await widget.onApply(configuration);
      if (mounted && applied) {
        Navigator.pop(context);
      }
    } on ArgumentError catch (error) {
      setState(() => _error = error.message?.toString() ?? error.toString());
    }
  }

  int _parsePositive(TextEditingController controller, String field) {
    final value = int.tryParse(controller.text.trim());
    if (value == null || value <= 0) {
      throw ArgumentError('$field must be greater than zero');
    }
    return value;
  }

  int _parseNonNegative(TextEditingController controller, String field) {
    final value = int.tryParse(controller.text.trim());
    if (value == null || value < 0) {
      throw ArgumentError('$field must not be negative');
    }
    return value;
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
            Text(
              'Session settings',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            _NumberField(
              controller: _downloadsController,
              label: 'Concurrent files',
            ),
            _NumberField(
              controller: _connectionsController,
              label: 'Global connections',
            ),
            _NumberField(
              controller: _perFileController,
              label: 'Connections per file',
            ),
            _NumberField(
              controller: _partSizeController,
              label: 'Minimum part size (MB)',
            ),
            _NumberField(
              controller: _checkpointController,
              label: 'Checkpoint interval (KB)',
            ),
            _NumberField(
              controller: _retriesController,
              label: 'Retry attempts',
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _apply,
              child: const Text('Apply settings'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _TransferEntry {
  _TransferEntry({required this.request, required this.task});

  DownloadRequest request;
  DownloadTask task;
  DownloadUpdate? update;
  DateTime? _sampleAt;
  int _sampleBytes = 0;
  double bytesPerSecond = 0;

  void record(DownloadUpdate next) {
    final now = DateTime.now();
    final previousAt = _sampleAt;
    if (previousAt != null && next.receivedBytes >= _sampleBytes) {
      final elapsedMicroseconds = now.difference(previousAt).inMicroseconds;
      if (elapsedMicroseconds > 0) {
        final instant =
            (next.receivedBytes - _sampleBytes) *
            Duration.microsecondsPerSecond /
            elapsedMicroseconds;
        bytesPerSecond =
            bytesPerSecond == 0
                ? instant
                : (bytesPerSecond * 0.7) + (instant * 0.3);
      }
    }
    if (next.status == DownloadStatus.paused ||
        next.status == DownloadStatus.validating ||
        next.status == DownloadStatus.completed ||
        next.status == DownloadStatus.failed ||
        next.status == DownloadStatus.cancelled) {
      bytesPerSecond = 0;
    }
    _sampleAt = now;
    _sampleBytes = next.receivedBytes;
  }

  void resetTelemetry() {
    _sampleAt = null;
    _sampleBytes = 0;
    bytesPerSecond = 0;
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _formatSpeed(double bytesPerSecond) =>
    '${_formatBytes(bytesPerSecond.round())}/s';

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
