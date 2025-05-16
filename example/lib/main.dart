import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:resumable_downloader/resumable_downloader.dart';

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
  late final DownloadManager _downloadManager;

  final String downloadUrl =
      'https://archive.org/download/tomandjerry_1080p/S1940E01%20-%20Puss%20Gets%20The%20Boot%20%281080p%20BluRay%20x265%20Ghost%29.mp4';
  double _progress = 0.0;
  bool _isDownloading = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _initializeDownloader();
  }

  Future<void> _initializeDownloader() async {
    final baseDir = await getApplicationDocumentsDirectory();

    _downloadManager = DownloadManager(
      subDir: 'downloads',
      baseDirectory: baseDir,
      fileExistsStrategy: FileExistsStrategy.resume,
      maxConcurrentDownloads: 2,
      maxRetries: 2,
      delayBetweenRetries: Duration.zero,
      logger: (log) => debugPrint('[${log.level.name}] ${log.message}'),
    );
  }

  Future<void> _startDownload() async {
    setState(() {
      _isDownloading = true;
      _status = 'Starting download...';
    });

    try {
      final file = await _downloadManager.getFile(
        QueueItem(
          url: downloadUrl,
          fileName: 'download_file', // optional
          progressCallback: (progressStream) {
            progressStream.listen((progress) {
              setState(() {
                _progress = progress;
                _status =
                    'Downloading... ${(_progress * 100).toStringAsFixed(0)}%';
              });
            });
          },
        ),
      );

      setState(() {
        _status = 'Download complete: ${file?.path}';
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

  void _cancelAll() {
    _downloadManager.cancelAll();
    setState(() {
      _status = 'All downloads canceled';
      _progress = 0.0;
      _isDownloading = false;
    });
  }

  void _deleteFile() {
    _downloadManager.deleteContentFile(
      QueueItem(
        url: downloadUrl,
        fileName: 'download_file', // optional
      ),
    );
    setState(() {
      _status = 'File deleted.';
      _progress = 0.0;
      _isDownloading = false;
    });
  }

  @override
  void dispose() {
    _downloadManager.dispose();
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
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 16),
            Text(_status, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isDownloading ? null : _startDownload,
              child: const Text('Start Download'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _isDownloading ? _cancelAll : null,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Cancel Download'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _isDownloading ? null : _deleteFile,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete File'),
            ),
          ],
        ),
      ),
    );
  }
}
