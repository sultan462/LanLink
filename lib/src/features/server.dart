import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';
import 'received_file.dart';
import '../model/ReceiveStatus.dart';

class TransferServer {
  final int port;
  final Directory saveDirectory;
  final Duration metadataTimeout;
  final Duration bodyTimeout;
  final ReceivedFile Function(Directory, String) _createFile;
  ServerSocket? _serverSocket;
  Future<void>? _starting;
  Future<void>? _stopping;
  Future<void>? _disposing;
  bool _accepting = false;
  bool _disposed = false;
  final Set<_ReceiveConnection> _connections = {};
  final StreamController<ReceiveStatus> _status =
      StreamController<ReceiveStatus>.broadcast();

  TransferServer({
    required this.saveDirectory,
    this.port = 5050,
    this.metadataTimeout = kMetadataTimeout,
    this.bodyTimeout = const Duration(seconds: 30),
    ReceivedFile Function(Directory, String)? createFile,
  }) : _createFile = createFile ?? ReceivedFile.new;

  Stream<ReceiveStatus> get statusStream => _status.stream;
  int get boundPort => _serverSocket?.port ?? port;

  Future<void> start() {
    if (_disposed) return Future.error(StateError('Receiver is disposed'));
    if (_stopping != null) {
      return Future.error(StateError('Receiver is stopping'));
    }
    if (_starting != null) return _starting!;
    if (_serverSocket != null) return Future.value();
    _accepting = true;
    return _starting = _start();
  }

  Future<void> _start() async {
    try {
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      if (!_accepting) {
        await server.close();
        return;
      }
      _serverSocket = server;
      _status.add(ReceiveStatus.waiting);
      server.listen(
        _handleConnection,
        onError: (Object e, StackTrace st) {
          if (_accepting) _status.addError(e, st);
        },
      );
    } finally {
      _starting = null;
    }
  }

  void _handleConnection(Socket socket) {
    if (!_accepting) {
      socket.destroy();
      return;
    }
    final connection = _ReceiveConnection(
      socket,
      saveDirectory,
      _status,
      metadataTimeout,
      bodyTimeout,
      _createFile,
    );
    _connections.add(connection);
    unawaited(
      connection.run().whenComplete(() => _connections.remove(connection)),
    );
  }

  Future<void> stop() {
    _accepting = false;
    for (final connection in _connections) {
      connection.cancel();
    }
    return _stopping ??= _stop();
  }

  Future<void> _stop() async {
    try {
      // Binding may finish after stop was requested; _start closes that socket.
      try {
        await _starting;
      } catch (_) {
        // The caller of start receives its startup failure.
      }
      await _serverSocket?.close();
      _serverSocket = null;
      await Future.wait(_connections.map((c) => c.done));
    } finally {
      _stopping = null;
    }
  }

  Future<void> dispose() {
    _disposed = true;
    return _disposing ??= _dispose();
  }

  Future<void> _dispose() async {
    await stop();
    await _status.close();
  }
}

class _ReceiveConnection {
  final Socket socket;
  final Directory directory;
  final StreamController<ReceiveStatus> status;
  final Duration metadataTimeout;
  final Duration bodyTimeout;
  final ReceivedFile Function(Directory, String) createFile;
  final Completer<void> _done = Completer();
  late final TransferReader _reader = TransferReader(socket);
  bool _cancelled = false;
  ReceivedFile? _file;
  int? _id;

  _ReceiveConnection(
    this.socket,
    this.directory,
    this.status,
    this.metadataTimeout,
    this.bodyTimeout,
    this.createFile,
  );

  Future<void> get done => _done.future;

  void cancel() {
    _cancelled = true;
    socket.destroy();
    unawaited(_reader.cancel());
  }

  void _checkCancelled() {
    if (_cancelled) throw const TransferException('Reception cancelled');
  }

  Future<void> _reply(Map<String, dynamic> message) async {
    socket.add(
      MessageProtocol.encode(
        jsonEncode({'protocol': kProtocolVersion, ...message}),
      ),
    );
    await socket.flush().timeout(metadataTimeout);
  }

  Future<void> run() async {
    // Observe socket write-side errors from the moment the connection exists.
    unawaited(
      socket.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    Object? failure;
    StackTrace? trace;
    try {
      final hello = await _reader.readFrame(timeout: metadataTimeout);
      _checkCancelled();
      if (hello == null) return;
      final handshake = MessageProtocol.decodeObject(hello);
      if (handshake['protocol'] != kProtocolVersion ||
          handshake['type'] != 'hello') {
        throw const TransferException(
          'Unsupported peer: LANLink protocol 2 required',
        );
      }
      await _reply({'type': 'ready'});
      while (true) {
        final message = await _reader.readFrame(timeout: metadataTimeout);
        _checkCancelled();
        if (message == null || message == kCloseWord) break;
        final meta = MessageProtocol.decodeObject(message);
        final size = meta['size'];
        final id = meta['id'];
        if (meta['protocol'] != kProtocolVersion ||
            meta['type'] != 'file' ||
            id is! int ||
            id < 1 ||
            size is! int ||
            size < 0) {
          throw const FormatException('Invalid file metadata');
        }
        _id = id;
        final name = ReceivedFile.validateName(meta['name']);
        _file = createFile(directory, name);
        status.add(ReceiveStatus.incoming);
        await _file!.open();
        _checkCancelled();
        var remaining = size;
        while (remaining > 0) {
          final bytes = await _reader.readSome(remaining).timeout(bodyTimeout);
          _checkCancelled();
          if (bytes == null) {
            throw const TransferException(
              'Connection closed mid-transfer (truncated file)',
            );
          }
          await _file!.write(bytes);
          remaining -= bytes.length;
        }
        _checkCancelled();
        final savedName = await _file!.commit(_checkCancelled);
        await _file!.dispose();
        _file = null;
        status.add(ReceiveStatus.completed);
        await _reply({'type': 'saved', 'id': _id, 'name': savedName});
        _id = null;
      }
    } catch (e, st) {
      failure = e;
      trace = st;
    } finally {
      try {
        await _file?.dispose();
      } catch (e, st) {
        failure = TransferException(
          '${failure ?? 'Transfer failed'}; cleanup failed: $e',
        );
        trace = st;
      }
      if (failure != null) {
        status.addError(failure, trace);
        if (!_cancelled) {
          try {
            await _reply({
              'type': 'error',
              'id': _id,
              'message': '$failure'.substring(
                0,
                '$failure'.length.clamp(0, 2000),
              ),
            });
          } catch (_) {
            // The peer may already be gone. The local error is still reported.
          }
        }
      }
      socket.destroy();
      await _reader.cancel();
      _done.complete();
    }
  }
}
