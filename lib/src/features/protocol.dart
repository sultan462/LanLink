import 'dart:convert';

const int kHeaderSize = 64;
const String kCloseWord = 'DISCONNECT';

class MessageProtocol {
  /// Turn one message into the exact bytes to put on the socket.
  static List<int> encode(String message) {
    // Body: the payload as UTF-8 bytes. Length is counted in BYTES, not
    // characters — utf8.encode expands multi-byte code points, so the count
    // we write here is exactly what the decoder will slice back off.
    final List<int> body = utf8.encode(message);

    // The decimal byte-count must fit inside the fixed field. It always will
    // in practice (kHeaderSize=64 digits ≈ 10^64 bytes), but assert the
    // invariant rather than silently emit a malformed frame.
    final String count = body.length.toString();
    assert(count.length <= kHeaderSize, 'body length overflows header field');

    // Header: the count rendered as ASCII, right-padded with spaces to EXACTLY
    // kHeaderSize bytes. e.g. 11 -> "11" + 62 spaces. The fixed width is what
    // lets the decoder peel off a header with no delimiter.
    final List<int> header = utf8.encode(count.padRight(kHeaderSize));

    // header (kHeaderSize bytes) followed by body (length bytes)
    return [...header, ...body];
  }
}

class MessageParser {
  final List<int> _buffer = <int>[];
  int? _expectedBodyLength; // null = waiting for a header

  /// Feed raw bytes. Returns every complete message now fully available
  /// (zero, one, or many).
  List<String> addBytes(List<int> chunk) {
    _buffer.addAll(chunk);
    final List<String> messages = <String>[];

    while (true) {
      if (_expectedBodyLength == null) {
        // No header read yet — need a full header to learn the next body size.
        if (_buffer.length < kHeaderSize) break; // wait for more bytes
        final header = _buffer.sublist(0, kHeaderSize);
        _buffer.removeRange(0, kHeaderSize);
        _expectedBodyLength = int.parse(utf8.decode(header).trim());
      } else {
        // Body size known — do we have all of it yet?
        if (_buffer.length < _expectedBodyLength!) break; // wait for more
        final body = _buffer.sublist(0, _expectedBodyLength!);
        _buffer.removeRange(0, _expectedBodyLength!);
        messages.add(utf8.decode(body));
        _expectedBodyLength = null; // ready for the next header
      }
    }

    return messages;
  }
}
