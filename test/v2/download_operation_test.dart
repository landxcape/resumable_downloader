import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/resumable_downloader.dart';
import 'package:resumable_downloader/src/v2/download_operation.dart'
    show createDownloadOperation;
import 'package:resumable_downloader/src/v2/download_task.dart'
    show DownloadTaskController;

import '../support/range_test_server.dart';

void main() {
  late Directory directory;
  late RangeTestServer server;
  late DownloadManager manager;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('rd-v2-operation-');
    server = await RangeTestServer.start(
      bytes: List<int>.generate(64, (index) => index),
      responseDelay: const Duration(milliseconds: 20),
    );
    manager = DownloadManager(baseDirectory: directory);
  });

  tearDown(() async {
    await manager.dispose();
    await server.close();
    await directory.delete(recursive: true);
  });

  test('later B-only operation never includes A C or D', () async {
    final requests = <DownloadRequest>[
      DownloadRequest(url: server.uri, fileName: 'a.bin'),
      DownloadRequest(url: server.uri, fileName: 'b.bin'),
      DownloadRequest(url: server.uri, fileName: 'c.bin'),
      DownloadRequest(url: server.uri, fileName: 'd.bin'),
    ];
    final initial = manager.startOperation(requests);
    await initial.result;

    final later = manager.startOperation(<DownloadRequest>[
      requests[1],
    ], priority: DownloadPriority.foreground);
    final updates = later.updates.toList();

    await later.result;
    final taskIds = (await updates).map((update) => update.taskId).toSet();

    expect(later.tasks, hasLength(1));
    expect(taskIds, <String>{later.tasks.single.id});
    expect(
      taskIds.intersection(initial.tasks.map((task) => task.id).toSet()),
      isEmpty,
    );
  });

  test('active B is one physical task in two operations', () async {
    final request = DownloadRequest(url: server.uri, fileName: 'b.bin');
    final first = manager.startOperation(<DownloadRequest>[request]);

    await first.tasks.single.updates.firstWhere(
      (update) => update.status == DownloadStatus.downloading,
    );
    final second = manager.startOperation(<DownloadRequest>[
      request,
    ], priority: DownloadPriority.foreground);

    expect(identical(first.tasks.single, second.tasks.single), isTrue);
    await Future.wait(<Future<List<File>>>[first.result, second.result]);
  });

  test('operation result preserves request order', () async {
    final operation = manager.startOperation(<DownloadRequest>[
      DownloadRequest(url: server.uri, fileName: 'c.bin'),
      DownloadRequest(url: server.uri, fileName: 'a.bin'),
      DownloadRequest(url: server.uri, fileName: 'b.bin'),
    ]);

    final files = await operation.result;

    expect(
      files.map((file) => file.path.split(Platform.pathSeparator).last),
      <String>['c.bin', 'a.bin', 'b.bin'],
    );
  });

  test(
    'equivalent inputs share one task but retain result positions',
    () async {
      final request = DownloadRequest(url: server.uri, fileName: 'same.bin');
      final operation = manager.startOperation(<DownloadRequest>[
        request,
        request,
      ]);

      final files = await operation.result;

      expect(operation.tasks, hasLength(2));
      expect(identical(operation.tasks.first, operation.tasks.last), isTrue);
      expect(files, hasLength(2));
      expect(files.first.path, files.last.path);
    },
  );

  test('empty operation completes with no updates', () async {
    final operation = manager.startOperation(const <DownloadRequest>[]);

    expect(await operation.result, isEmpty);
    expect(await operation.updates.toList(), isEmpty);
    expect(operation.isCompleted, isTrue);
  });

  test('listening twice never starts work again', () async {
    var validationCalls = 0;
    final operation = manager.startOperation(<DownloadRequest>[
      DownloadRequest(
        url: server.uri,
        fileName: 'observed.bin',
        validator: (_) {
          validationCalls++;
          return true;
        },
      ),
    ]);
    final firstUpdates = operation.updates.toList();
    final secondUpdates = operation.updates.toList();

    await operation.result;
    final first = await firstUpdates;
    final second = await secondUpdates;

    expect(validationCalls, 1);
    expect(first, isNotEmpty);
    expect(second, isNotEmpty);
    expect(first.last.status, DownloadStatus.completed);
    expect(second.last.status, DownloadStatus.completed);
  });

  test(
    'operation replays frozen snapshots before newer live updates',
    () async {
      final a = DownloadTaskController('a');
      final b = DownloadTaskController('b');
      a.emit(
        DownloadUpdate(
          taskId: 'a',
          status: DownloadStatus.preparing,
          receivedBytes: 0,
        ),
      );
      b.emit(
        DownloadUpdate(
          taskId: 'b',
          status: DownloadStatus.downloading,
          receivedBytes: 0,
        ),
      );
      final operation = createDownloadOperation(
        id: 'operation',
        tasks: <DownloadTask>[a.task, b.task],
      );
      final bBytes = <int>[];
      final receivedAll = Completer<void>();
      late final StreamSubscription<DownloadUpdate> subscription;
      subscription = operation.updates.listen((update) {
        if (update.taskId == 'a') {
          b.emit(
            DownloadUpdate(
              taskId: 'b',
              status: DownloadStatus.downloading,
              receivedBytes: 1,
            ),
          );
          b.emit(
            DownloadUpdate(
              taskId: 'b',
              status: DownloadStatus.downloading,
              receivedBytes: 2,
            ),
          );
        } else {
          bBytes.add(update.receivedBytes);
          if (bBytes.length == 3) {
            receivedAll.complete();
          }
        }
      });

      await receivedAll.future;

      expect(bBytes, <int>[0, 1, 2]);
      await subscription.cancel();
      a.complete(File('${directory.path}/a.bin'));
      b.complete(File('${directory.path}/b.bin'));
    },
  );

  test('terminal update callback starts a fresh operation', () async {
    var validationCalls = 0;
    final request = DownloadRequest(
      url: server.uri,
      fileName: 'terminal.bin',
      validator: (_) {
        validationCalls++;
        return true;
      },
    );
    final first = manager.startOperation(<DownloadRequest>[request]);
    final startedAgain = Completer<DownloadOperation>();
    final subscription = first.updates.listen((update) {
      if (update.status == DownloadStatus.completed &&
          !startedAgain.isCompleted) {
        startedAgain.complete(
          manager.startOperation(<DownloadRequest>[request]),
        );
      }
    });

    await first.result;
    final second = await startedAgain.future;
    await second.result;

    expect(identical(first.tasks.single, second.tasks.single), isFalse);
    expect(validationCalls, 2);
    await subscription.cancel();
  });

  test('throwing request iterable starts no partial operation', () async {
    Iterable<DownloadRequest> requests() sync* {
      yield DownloadRequest(url: server.uri, fileName: 'orphan.bin');
      throw StateError('broken catalog');
    }

    expect(
      () => manager.startOperation(requests()),
      throwsA(isA<StateError>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(server.requestedPaths, isEmpty);
  });

  test('foreground duplicate promotes pending B behind active A', () async {
    await manager.dispose();
    manager = DownloadManager(
      baseDirectory: directory,
      configuration: DownloadConfiguration(
        maxConcurrentDownloads: 1,
        maxConcurrentConnections: 1,
        maxConnectionsPerDownload: 1,
      ),
    );
    final a = DownloadRequest(
      url: server.uri.replace(path: '/a.bin'),
      fileName: 'a.bin',
    );
    final b = DownloadRequest(
      url: server.uri.replace(path: '/b.bin'),
      fileName: 'b.bin',
    );
    final c = DownloadRequest(
      url: server.uri.replace(path: '/c.bin'),
      fileName: 'c.bin',
    );
    final active = manager.startOperation(<DownloadRequest>[a]);
    await active.tasks.single.updates.firstWhere(
      (update) => update.status == DownloadStatus.downloading,
    );
    final pending = manager.startOperation(<DownloadRequest>[c, b]);
    final foreground = manager.startOperation(<DownloadRequest>[
      b,
    ], priority: DownloadPriority.foreground);

    expect(identical(foreground.tasks.single, pending.tasks[1]), isTrue);
    await Future.wait(<Future<List<File>>>[active.result, pending.result]);

    final firstSeen = <String>[];
    for (final path in server.requestedPaths) {
      if (!firstSeen.contains(path)) {
        firstSeen.add(path);
      }
    }
    expect(firstSeen.take(3), <String>['/a.bin', '/b.bin', '/c.bin']);
  });

  test('completed A-D followed by B validates only B', () async {
    final calls = <String, int>{};

    DownloadRequest request(
      String id, {
      ExistingFilePolicy policy = ExistingFilePolicy.resume,
    }) {
      return DownloadRequest(
        url: server.uri.replace(path: '/$id.bin'),
        fileName: '$id.bin',
        existingFilePolicy: policy,
        validator: (_) {
          calls[id] = (calls[id] ?? 0) + 1;
          return true;
        },
      );
    }

    final initial = manager.startOperation(<DownloadRequest>[
      request('a'),
      request('b'),
      request('c'),
      request('d'),
    ]);
    await initial.result;
    calls.clear();

    final later = manager.startOperation(<DownloadRequest>[
      request('b'),
    ], priority: DownloadPriority.foreground);
    final updates = later.updates.toList();
    await later.result;

    expect(calls, <String, int>{'b': 1});
    expect(later.tasks, hasLength(1));
    expect((await updates).map((update) => update.taskId).toSet(), <String>{
      later.tasks.single.id,
    });
    expect(
      later.tasks.single.id,
      isNot(anyOf(initial.tasks.map((task) => task.id))),
    );
  });

  test('completed B applies only its requested existing-file policy', () async {
    final baseRequest = DownloadRequest(
      url: server.uri.replace(path: '/b.bin'),
      fileName: 'b.bin',
    );
    await manager.download(baseRequest);

    var validationCalls = 0;
    final beforeResume = server.requestedPaths.length;
    await manager.startOperation(<DownloadRequest>[
      DownloadRequest(
        url: baseRequest.url,
        fileName: baseRequest.fileName,
        validator: (_) {
          validationCalls++;
          return true;
        },
      ),
    ]).result;
    expect(validationCalls, 1);
    expect(server.requestedPaths, hasLength(beforeResume));

    final beforeReplace = server.requestedPaths.length;
    await manager.startOperation(<DownloadRequest>[
      DownloadRequest(
        url: baseRequest.url,
        fileName: baseRequest.fileName,
        existingFilePolicy: ExistingFilePolicy.replace,
      ),
    ]).result;
    expect(server.requestedPaths.length, greaterThan(beforeReplace));
    expect(server.requestedPaths.skip(beforeReplace).toSet(), <String>{
      '/b.bin',
    });

    final beforeFail = server.requestedPaths.length;
    await expectLater(
      manager.startOperation(<DownloadRequest>[
        DownloadRequest(
          url: baseRequest.url,
          fileName: baseRequest.fileName,
          existingFilePolicy: ExistingFilePolicy.fail,
        ),
      ]).result,
      throwsA(isA<StateError>()),
    );
    expect(server.requestedPaths, hasLength(beforeFail));
  });
}
