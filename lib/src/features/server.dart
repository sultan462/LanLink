import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'protocol.dart'; // for kHeaderSize
import '../model/ReceiveStatus.dart';

/// The TRANSPORT shell for the listening side. Owns the ServerSocket and the
/// per-connection lifecycle, writes incoming files into [saveDirectory], and
/// publishes progress as a status stream.
///
/// Framing knowledge stays in protocol.dart; this file only ORCHESTRATES modes
/// (framed metadata -> raw file bytes) on top of it.
class TransferServer {
  final int port;
  final Directory saveDirectory;

  ServerSocket? _serverSocket;

  // broadcast so multiple listeners (e.g. UI + logging) can watch; a failed
  // transfer is delivered as a stream ERROR, never as a status value.
  final StreamController<ReceiveStatus> _status =
      StreamController<ReceiveStatus>.broadcast();

  TransferServer({required this.saveDirectory, this.port = 5050});

  /// What `Core.receiveStatusStream()` forwards to the UI.
  Stream<ReceiveStatus> get statusStream => _status.stream;

  Future<void> start() async {
    // anyIPv4 == 0.0.0.0: listen on EVERY interface so LAN peers can reach us,
    // not just this machine. (SO_REUSEADDR is set by the Dart VM by default.)
    _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _status.add(ReceiveStatus.waiting);

    _serverSocket!.listen(
      _handleConnection,
      onError: (e, st) =>
          _status.addError(e, st), // listen-socket level failure
    );
  }

  void _handleConnection(Socket client) {
    // One receive context per connection: its own buffer + mode state. Two peers'
    // byte streams must never share framing state, or their bytes interleave.
    _ReceiveConnection(
      socket: client,
      saveDirectory: saveDirectory,
      status: _status,
    ).start();
  }

  /// Stop accepting connections and release the port. Keeps the status stream
  /// alive so the server can be restarted; use [dispose] to tear it down fully.
  Future<void> stop() async {
    await _serverSocket?.close();
    _serverSocket = null;
  }

  Future<void> dispose() async {
    await stop();
    await _status.close();
  }
}

/// Handles ONE incoming connection.
///
/// The state machine: a connection begins in FRAMED mode, reading a single
/// metadata frame ({name, size}) in the shared wire format. Once that frame is
/// complete it flips to RAW mode and streams exactly `size` bytes straight to a
/// file on disk, then flips back for the next file. All byte handling goes
/// through ONE buffer and ONE drain loop, which is what makes a chunk that
/// crosses the boundary (in either direction) just work.
class _ReceiveConnection {
  final Socket socket;
  final Directory saveDirectory;
  final StreamController<ReceiveStatus> status;

  // the single source of truth for unconsumed bytes on this connection
  final List<int> _buffer = [];

  // mode state
  bool _receivingFile = false;
  IOSink? _sink;
  int _bytesRemaining = 0;

  _ReceiveConnection({
    required this.socket,
    required this.saveDirectory,
    required this.status,
  });

  void start() => unawaited(_run());

  Future<void> _run() async {
    try {
      // `await for` (not .listen) so we can await disk flush/close INLINE and
      // keep status events strictly ordered, even for tiny back-to-back files.
      await for (final chunk in socket) {
        _buffer.addAll(chunk);
        await _drain();
      }
      // socket closed cleanly. If a file was still in flight, it was truncated.
      if (_receivingFile) {
        await _abort();
        status.addError(
          const SocketException('Connection closed mid-transfer'),
        );
      }
    } catch (e, st) {
      await _abort();
      status.addError(e, st); // surface ANY failure as a stream error
    } finally {
      await socket.close(); // release our side — otherwise it lingers in CLOSE_WAIT
    }
  }

  /// Consume as much of [_buffer] as the current mode allows, looping so that a
  /// single chunk holding [file tail][next metadata][next file head] is fully
  /// processed in one pass.
  Future<void> _drain() async {
    while (true) {
      if (_receivingFile) {
        if (_buffer.isEmpty) return;

        // take only what THIS file still needs — never read into the next frame
        final take = min(_buffer.length, _bytesRemaining);
        _sink!.add(_buffer.sublist(0, take));
        _buffer.removeRange(0, take);
        _bytesRemaining -= take;

        if (_bytesRemaining == 0) {
          await _finishFile(); // flush+close+announce, ordered
          // loop continues: whatever's left in _buffer is the NEXT metadata frame
        } else {
          return; // buffer drained, file still incomplete — wait for more bytes
        }
      } else {
        // FRAMED mode: peel ONE metadata frame. Header is a fixed kHeaderSize
        // field carrying the body length as padded text (the protocol.dart format).
        if (_buffer.length < kHeaderSize) return; // header not fully here yet

        final header = utf8.decode(_buffer.sublist(0, kHeaderSize)).trim();
        final metaLen = int.parse(header);

        if (_buffer.length < kHeaderSize + metaLen) return; // body not all here

        final metaBytes = _buffer.sublist(kHeaderSize, kHeaderSize + metaLen);
        _buffer.removeRange(0, kHeaderSize + metaLen);

        final message = utf8.decode(metaBytes);
        if (message == kCloseWord) return; // peer is done — not a file frame

        _beginFile(message);
        // loop continues: remaining _buffer bytes are now FILE bytes (raw mode)
      }
    }
  }

  void _beginFile(String metaJson) {
    final meta = jsonDecode(metaJson) as Map<String, dynamic>;
    final size = meta['size'] as int;

    // SECURITY: never trust the sender's path. Take only the basename so a name
    // like "../../etc/passwd" can't escape saveDirectory.
    final rawName = (meta['name'] as String?) ?? 'received_file';
    final safeName = Uri.file(rawName).pathSegments.last;
    final dest = File('${saveDirectory.path}/$safeName');

    _sink = dest.openWrite();
    _bytesRemaining = size;
    _receivingFile = true;
    status.add(ReceiveStatus.incoming);
    // size == 0 is handled naturally: the drain loop's raw branch takes 0 bytes,
    // sees _bytesRemaining == 0, and finishes immediately.
  }

  Future<void> _finishFile() async {
    final sink = _sink;
    _sink = null;
    _receivingFile = false;
    _bytesRemaining = 0;

    // flush+close FIRST so the file is fully on disk before we say "completed".
    await sink?.flush();
    await sink?.close();

    status.add(ReceiveStatus.completed);
    // stays "completed" until the next file's _beginFile() moves it to
    // "incoming" — re-adding "waiting" here instantly overwrites it, so the
    // UI never gets a frame where the user can see the file arrived.
  }

  Future<void> _abort() async {
    final sink = _sink;
    _sink = null;
    _receivingFile = false;
    _bytesRemaining = 0;
    _buffer.clear();
    await sink?.close();
    // (optional) delete the partial file here so half-received data isn't left behind
  }
}
