import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'protocol.dart';

class TransferClient {
  final String host;
  final List<String> alternateHosts;
  final int port;
  final Duration connectTimeout;
  final Duration acknowledgmentTimeout;
  Socket? _socket;
  TransferReader? _reader;
  bool _sending = false;
  int _nextId = 0;

  TransferClient({
    required this.host,
    this.port = 5050,
    this.alternateHosts = const [],
    this.connectTimeout = const Duration(seconds: 5),
    this.acknowledgmentTimeout = kAcknowledgmentTimeout,
  });

  Future<void> connect() async {
    if (_socket != null) throw StateError('Already connected');
    Object? lastError;
    for (final address in {host, ...alternateHosts}) {
      Socket? socket;
      TransferReader? reader;
      try {
        socket = await Socket.connect(address, port, timeout: connectTimeout);
        unawaited(
          socket.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
        reader = TransferReader(socket);
        socket.add(
          MessageProtocol.encode(
            jsonEncode({'protocol': kProtocolVersion, 'type': 'hello'}),
          ),
        );
        await socket.flush().timeout(connectTimeout);
        final reply = await reader.readFrame(timeout: acknowledgmentTimeout);
        _validateReply(reply, 'ready');
        _socket = socket;
        _reader = reader;
        return;
      } catch (e) {
        lastError = e;
        socket?.destroy();
        await reader?.cancel();
      }
    }
    throw TransferException(
      'Could not connect to a compatible LANLink receiver: $lastError',
    );
  }

  static Map<String, dynamic> _validateReply(
    String? message,
    String type, {
    int? id,
  }) {
    if (message == null) {
      throw const TransferException(
        'Receiver disconnected without confirmation; file saving is unconfirmed',
      );
    }
    final reply = MessageProtocol.decodeObject(message);
    if (reply['protocol'] != kProtocolVersion) {
      throw const TransferException(
        'Unsupported acknowledgment protocol; upgrade both peers',
      );
    }
    if (reply['type'] == 'error') {
      throw TransferException(
        'Receiver could not save the file: ${reply['message']}',
      );
    }
    if (reply['type'] != type || (id != null && reply['id'] != id)) {
      throw const TransferException(
        'Invalid receiver acknowledgment; file saving is unconfirmed',
      );
    }
    return reply;
  }

  void send(String message) {
    final socket = _socket;
    if (socket == null) throw StateError('Socket is not connected');
    if (_sending) throw StateError('A file transfer is already in progress');
    socket.add(MessageProtocol.encode(message));
  }

  Future<void> disconnect() async {
    final socket = _socket;
    final reader = _reader;
    _socket = null;
    _reader = null;
    if (socket == null) return;
    try {
      if (!_sending) {
        socket.add(MessageProtocol.encode(kCloseWord));
        await socket.flush().timeout(connectTimeout);
      }
    } catch (_) {
      // Disconnect is also the cleanup path after a failed or cancelled send.
    } finally {
      socket.destroy();
      await reader?.cancel();
    }
  }

  Future<void> sendFile(
    String filePath, {
    void Function(double)? onProgress,
  }) async {
    final socket = _socket;
    final reader = _reader;
    if (socket == null || reader == null) throw StateError('Not connected');
    if (_sending) throw StateError('A file transfer is already in progress');
    _sending = true;
    try {
      final file = File(filePath);
      final length = await file.length();
      final name = Uri.file(filePath).pathSegments.last;
      final id = ++_nextId;
      socket.add(
        MessageProtocol.encode(
          jsonEncode({
            'protocol': kProtocolVersion,
            'type': 'file',
            'id': id,
            'name': name,
            'size': length,
          }),
        ),
      );

      // Listen concurrently with upload so an early receiver failure interrupts
      // sending. Future.wait installs error handlers on BOTH operations at once.
      final response = reader.readFrame().then((value) {
        _validateReply(value, 'saved', id: id);
      });
      final uploaded = _upload(socket, file, length, onProgress);
      await Future.wait<void>([
        response,
        uploaded.then(
          (_) => response.timeout(
            acknowledgmentTimeout,
            onTimeout: () {
              throw const TransferException(
                'Timed out waiting for receiver acknowledgment; file saving is unconfirmed',
              );
            },
          ),
        ),
      ], eagerError: true);
      onProgress?.call(1.0);
    } catch (_) {
      socket.destroy();
      await reader.cancel();
      _socket = null;
      _reader = null;
      rethrow;
    } finally {
      _sending = false;
    }
  }

  Future<void> _upload(
    Socket socket,
    File file,
    int length,
    void Function(double)? progress,
  ) async {
    var sent = 0;
    await socket.addStream(
      file.openRead(0, length).map((chunk) {
        sent += chunk.length;
        // Reserve 100% for the receiver's saved acknowledgment.
        progress?.call(length == 0 ? 0 : (sent / length).clamp(0.0, 0.99));
        return chunk;
      }),
    );
    if (sent != length) {
      throw const TransferException('Source file changed during transfer');
    }
    await socket.flush();
  }
}
