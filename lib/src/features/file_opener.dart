import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FileOpenException implements Exception {
  final String message;
  const FileOpenException(this.message);
  @override
  String toString() => message;
}

class FileOpener {
  static const _channel = MethodChannel('lanlink/file_opener');
  static Future<void> open(String path) async {
    if (!await File(path).exists()) {
      throw FileSystemException('File not found', path);
    }
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await _channel.invokeMethod<void>('open', {'path': path});
      } on PlatformException catch (e) {
        throw FileOpenException(
          e.message ?? 'The platform could not open this file',
        );
      } on MissingPluginException {
        throw const FileOpenException(
          'File opening is unavailable on this device',
        );
      }
    } else if (Platform.isMacOS) {
      await Process.start('open', [path]);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [path]);
    } else if (Platform.isWindows) {
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', path]);
    } else {
      throw const FileOpenException(
        'File opening is unavailable on this platform',
      );
    }
  }
}
