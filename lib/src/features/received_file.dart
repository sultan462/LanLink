import 'dart:io';

/// One staged file. No file in the received-files list is touched until commit.
/// Awaited RandomAccessFile operations replace IOSink so open/write/flush/close
/// errors all belong to the same transfer's try/catch, including empty files.
class ReceivedFile {
  final Directory destination;
  final String name;
  Directory? _temporaryDirectory;
  File? _temporaryFile;
  RandomAccessFile? _handle;

  ReceivedFile(this.destination, this.name);

  static String validateName(Object? value) {
    if (value is! String) throw const FormatException('Missing filename');
    final name = value.replaceAll('\\', '/').split('/').last;
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        RegExp(r'[\x00-\x1f<>:"|?*]').hasMatch(name) ||
        name.endsWith('.') ||
        name.endsWith(' ')) {
      throw const FormatException('Invalid filename');
    }
    return name;
  }

  Future<void> open() async {
    final staging = Directory('${destination.path}/.lanlink-partials');
    await staging.create(recursive: true);
    _temporaryDirectory = await staging.createTemp('transfer-');
    _temporaryFile = File('${_temporaryDirectory!.path}/body');
    _handle = await _temporaryFile!.open(mode: FileMode.write);
  }

  Future<void> write(List<int> bytes) async {
    await _handle!.writeFrom(bytes);
  }

  Future<String> commit(void Function() checkCancelled) async {
    await _handle!.flush();
    await _handle!.close();
    _handle = null;
    checkCancelled();

    final locks = Directory(
      '${destination.path}/.lanlink-partials/reservations',
    );
    await locks.create(recursive: true);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var number = 0; ; number++) {
      checkCancelled();
      final candidate = number == 0 ? name : '$stem ($number)$extension';
      final target = '${destination.path}/$candidate';
      final reservation = File('${locks.path}/$candidate');
      try {
        // Exclusive creation arbitrates even between separate receiver processes.
        await reservation.create(exclusive: true);
      } on PathExistsException {
        // The other writer may release its reservation before we inspect the
        // filesystem, so use the creation error itself to identify a collision.
        continue;
      }
      try {
        checkCancelled();
        if (FileSystemEntity.typeSync(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        // The reservation protects this name from other LANLink writers. There
        // is no async gap between the last cancellation/existence check and the
        // atomic rename on the same filesystem.
        _temporaryFile!.renameSync(target);
        _temporaryFile = null;
        return candidate;
      } finally {
        await reservation.delete();
      }
    }
  }

  Future<void> dispose() async {
    try {
      await _handle?.close();
    } finally {
      _handle = null;
      final directory = _temporaryDirectory;
      if (directory != null) {
        await directory.delete(recursive: true);
        _temporaryDirectory = null;
        _temporaryFile = null;
      }
    }
  }
}
