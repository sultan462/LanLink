import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

const int kHeaderSize = 64;
const String kCloseWord = 'DISCONNECT';
const int kProtocolVersion = 2;

/// Applies to metadata, handshakes, and acknowledgments (UTF-8 bytes).
const int kMaxMetadataBytes = 16 * 1024;
const Duration kMetadataTimeout = Duration(seconds: 10);
const Duration kAcknowledgmentTimeout = Duration(seconds: 30);

class TransferException implements Exception {
  final String message;
  const TransferException(this.message);

  @override
  String toString() => message;
}

class MessageProtocol {
  static List<int> encode(String message) {
    final body = utf8.encode(message);
    if (body.isEmpty || body.length > kMaxMetadataBytes) {
      throw const FormatException('Control frame must contain 1–16384 bytes');
    }
    return [
      ...ascii.encode(body.length.toString().padRight(kHeaderSize)),
      ...body,
    ];
  }

  static int decodeLength(List<int> header) {
    final text = ascii.decode(header);
    if (!RegExp(r'^[0-9]+ *$').hasMatch(text)) {
      throw const FormatException('Invalid frame length');
    }
    final length = int.tryParse(text.trim());
    if (length == null || length <= 0 || length > kMaxMetadataBytes) {
      throw const FormatException('Control frame must contain 1–16384 bytes');
    }
    return length;
  }

  static Map<String, dynamic> decodeObject(String message) {
    final value = jsonDecode(message);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object');
    }
    return value;
  }
}

/// Pull-based reader: retains at most one socket chunk plus one bounded frame.
/// It preserves bytes across metadata/body boundaries and applies backpressure
/// while the caller awaits disk I/O. Only one read may be active at a time.
class TransferReader {
  final StreamIterator<List<int>> _input;
  List<int> _chunk = const [];
  int _offset = 0;

  TransferReader(Stream<List<int>> input) : _input = StreamIterator(input);

  Future<List<int>?> readSome(int maximum) async {
    while (_offset == _chunk.length) {
      if (!await _input.moveNext()) return null;
      _chunk = _input.current;
      _offset = 0;
    }
    final end = min(_chunk.length, _offset + maximum);
    final bytes = _chunk.sublist(_offset, end);
    _offset = end;
    return bytes;
  }

  Future<List<int>?> _readExact(int count, {bool allowEof = false}) async {
    final result = BytesBuilder(copy: false);
    while (result.length < count) {
      final bytes = await readSome(count - result.length);
      if (bytes == null) {
        if (allowEof && result.isEmpty) return null;
        throw const TransferException(
          'Connection closed during a control frame',
        );
      }
      result.add(bytes);
    }
    return result.takeBytes();
  }

  Future<String?> readFrame({Duration? timeout}) {
    final frame = _readFrame();
    // A single deadline covers the entire header AND body, not each chunk.
    return timeout == null ? frame : frame.timeout(timeout);
  }

  Future<String?> _readFrame() async {
    final header = await _readExact(kHeaderSize, allowEof: true);
    if (header == null) return null;
    final length = MessageProtocol.decodeLength(header);
    final body = await _readExact(length);
    return utf8.decode(body!);
  }

  Future<void> cancel() => _input.cancel();
}
