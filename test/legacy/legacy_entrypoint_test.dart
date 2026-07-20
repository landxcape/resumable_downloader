import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/resumable_downloader_legacy.dart'
    as legacy;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy library exposes the current manager and models', () {
    final item = legacy.QueueItem(url: 'https://example.test/file.bin');
    final manager = legacy.DownloadManager(subDir: 'legacy');

    expect(item.url, 'https://example.test/file.bin');
    expect(manager, isA<legacy.DownloadManager>());
  });
}
