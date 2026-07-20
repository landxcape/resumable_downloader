import 'dart:async';

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
    return const MaterialApp(home: DownloadHomePage());
  }
}

class DownloadHomePage extends StatefulWidget {
  const DownloadHomePage({super.key});

  @override
  State<DownloadHomePage> createState() => _DownloadHomePageState();
}

class _DownloadHomePageState extends State<DownloadHomePage> {
  late final DownloadManager _downloadManager = DownloadManager(
    subdirectory: 'downloads',
    configuration: DownloadConfiguration(
      maxConcurrentDownloads: 2,
      maxConcurrentConnections: 4,
      maxConnectionsPerDownload: 3,
      maxRetries: 2,
    ),
  );

  final String downloadUrl =
      'https://archive.org/download/tomandjerry_1080p/S1940E01%20-%20Puss%20Gets%20The%20Boot%20%281080p%20BluRay%20x265%20Ghost%29.mp4';
  DownloadUpdate? _update;
  DownloadTask? _task;
  bool _isDownloading = false;
  String _status = '';

  Future<void> _startDownload() async {
    setState(() {
      _isDownloading = true;
      _status = 'Starting download...';
    });

    try {
      final task = _downloadManager.enqueue(
        DownloadRequest(
          url: Uri.parse(downloadUrl),
          fileName: 'download_file.mp4',
        ),
      );
      _task = task;
      task.updates.listen((update) {
        if (!mounted) {
          return;
        }
        setState(() {
          _update = update;
          _status = '${update.status.name}: ${update.receivedBytes} bytes';
        });
      });
      final file = await task.result;

      setState(() {
        _status = 'Download complete: ${file.path}';
      });
    } catch (e) {
      setState(() {
        _status = 'Download failed: $e';
      });
    } finally {
      setState(() {
        _isDownloading = false;
      });
    }
  }

  void _cancel() {
    unawaited(_task?.cancel() ?? Future<void>.value());
    setState(() {
      _status = 'Cancelling download...';
    });
  }

  @override
  void dispose() {
    unawaited(_downloadManager.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Resumable Downloader Example')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AdaptiveProgressBar(
              ranges: _update?.ranges ?? const <DownloadRangeUpdate>[],
            ),
            const SizedBox(height: 16),
            Text(_status, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isDownloading ? null : _startDownload,
              child: const Text('Start Download'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _isDownloading ? _cancel : null,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Cancel Download'),
            ),
          ],
        ),
      ),
    );
  }
}
