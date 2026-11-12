import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:path_provider/path_provider.dart';

import '../model/ReceiveStatus.dart';
import 'server.dart';

abstract interface class ReceiverAdvertisement {
  Future<void> initialize();
  Future<void> start();
  Future<void> stop();
}

class _BonjourAdvertisement implements ReceiverAdvertisement {
  final BonsoirBroadcast broadcast;
  _BonjourAdvertisement(String type, int port)
    : broadcast = BonsoirBroadcast(
        service: BonsoirService(
          name: '${Platform.localHostname}-lanlink',
          type: type,
          port: port,
        ),
      );

  @override
  Future<void> initialize() => broadcast.initialize();
  @override
  Future<void> start() => broadcast.start();
  @override
  Future<void> stop() => broadcast.stop();
}

/// Serializes native startup/teardown and invalidates pending startup immediately
/// when stop is requested. A late native completion is always followed by cleanup.
class ReceiverLifecycle {
  final Future<Directory> Function() _documentsDirectory;
  final TransferServer Function(Directory) _createServer;
  final ReceiverAdvertisement Function(int) _createAdvertisement;
  Future<void> _tail = Future.value();
  int _generation = 0;
  TransferServer? _server;
  ReceiverAdvertisement? _advertisement;

  ReceiverLifecycle({
    required String serviceType,
    Future<Directory> Function()? documentsDirectory,
    TransferServer Function(Directory)? createServer,
    ReceiverAdvertisement Function(int)? createAdvertisement,
  }) : _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       _createServer =
           createServer ??
           ((directory) => TransferServer(saveDirectory: directory)),
       _createAdvertisement =
           createAdvertisement ??
           ((port) => _BonjourAdvertisement(serviceType, port));

  Stream<ReceiveStatus> get statusStream {
    final server = _server;
    if (server == null) throw StateError('Receiver has not started');
    return server.statusStream;
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final operation = _tail.then((_) => action());
    // Keep serialization usable after an error, while the caller still receives it.
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> start() {
    final generation = ++_generation;
    return _enqueue(() async {
      await _cleanup();
      if (generation != _generation) return;
      var ready = false;
      try {
        final docs = await _documentsDirectory();
        if (generation != _generation) return;
        final directory = Directory('${docs.path}/LanLink');
        await directory.create(recursive: true);
        if (generation != _generation) return;
        final server = _server = _createServer(directory);
        await server.start();
        if (generation != _generation) return;
        final advertisement = _advertisement = _createAdvertisement(
          server.boundPort,
        );
        await advertisement.initialize();
        if (generation != _generation) return;
        await advertisement.start();
        ready = generation == _generation;
      } finally {
        if (!ready) await _cleanup();
      }
    });
  }

  Future<void> stop() {
    ++_generation;
    // Cancel active sockets immediately, even while a broadcast call is pending.
    final stoppingServer = _server?.stop() ?? Future<void>.value();
    final cleanup = _enqueue(_cleanup);
    return Future.wait([stoppingServer, cleanup]).then((_) {});
  }

  Future<void> _cleanup() async {
    final advertisement = _advertisement;
    final server = _server;
    _advertisement = null;
    _server = null;
    await Future.wait<void>([
      if (server != null) server.dispose(),
      if (advertisement != null) _stopAdvertisement(advertisement),
    ]);
  }

  Future<void> _stopAdvertisement(ReceiverAdvertisement advertisement) async {
    try {
      await advertisement.stop();
    } catch (_) {
      // Retain a failed native stop for a later retry instead of losing the
      // only handle to a potentially still-advertising resource.
      _advertisement = advertisement;
      rethrow;
    }
  }
}
