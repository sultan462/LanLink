import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'protocol.dart';

/// The TRANSPORT shell for the connecting side. It opens a Socket and sends
/// messages using the shared wire format. Like the server, it delegates all
/// framing to MessageProtocol and stays ignorant of the byte layout itself.
class TransferClient {
  final String host;
  final int port;
  Socket? _socket;

  TransferClient({required this.host, this.port = 5050});

  Future<void> connect() async {
    // open a Socket to (host, port)
    //   -> note: `host` here is the server's REAL reachable address (e.g. 127.0.0.1
    //      for same-machine tests, or its 192.168.x.x on the LAN). You never
    //      connect to 0.0.0.0 — that's a bind-side wildcard only.
    _socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
    if (_socket == null) {
      throw Exception('Failed to connect to $host:$port');
    }
  }

  void send(String message) {
    // use MessageProtocol.encode(message) to get the framed bytes, then write
    // them to the socket
    if (_socket == null) {
      throw Exception('Socket is not connected');
    }
    final bytes = MessageProtocol.encode(message);
    _socket!.add(bytes);
  }

  Future<void> disconnect() async {
    // send kCloseWord so the server can end its loop cleanly, flush, then close
    send("DISCONNECT");
    await _socket?.close();
  }

  Future<void> sendFile(
    String filePath, {
    void Function(double progress)? onProgress, // 0.0 → 1.0
  }) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('Not connected — call connect() before sendFile().');
    }

    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }

    final int length = await file.length();
    final String name = Uri.file(filePath).pathSegments.last;

    // 1. METADATA: a framed String message, sent through the existing protocol.
    //    The receiver decodes this first to learn the name and how many raw
    //    bytes will follow.
    final meta = jsonEncode({'name': name, 'size': length});
    socket.add(MessageProtocol.encode(meta));

    // 2. PAYLOAD: stream raw bytes from disk → socket, tapping each chunk for
    //    progress as it flows past. NOT a manual add() loop — see note below.
    int sent = 0;
    final piped = file.openRead().transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          sent += chunk.length;
          onProgress?.call(length == 0 ? 1.0 : sent / length);
          sink.add(chunk);
        },
      ),
    );

    await socket.addStream(piped); // respects backpressure (see below)
    await socket.flush();
  }
}
