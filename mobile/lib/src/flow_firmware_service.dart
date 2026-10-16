import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

class SavedFirmware {
  const SavedFirmware({required this.path, required this.name});

  final String path;
  final String name;
}

/// Contains only a user-facing message, never a response body or credentials.
class FlowFirmwareException implements Exception {
  const FlowFirmwareException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Logs in for one download; credentials and tokens only exist in memory.
/// A service belongs to one screen and cannot be reused after [close].
class FlowFirmwareService {
  FlowFirmwareService({
    HttpClient Function()? clientFactory,
    Future<Directory> Function()? documentsDirectory,
    this.requestTimeout = const Duration(seconds: 30),
    this.downloadTimeout = const Duration(minutes: 3),
    this.maxFirmwareBytes = 64 * 1024 * 1024,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory;

  static final _authUri = Uri.parse(
    'https://api.flowneuroscience.com/api/v2/auth/',
  );
  static final _firmwareUri = Uri.parse(
    'https://api.flowneuroscience.com/api/v2/firmware/'
    '8548778e-f6d6-4571-8eda-f6a7e4e0e7bc/',
  );
  static const _filenamePrefix = 'flow-firmware-8548778e-';

  final HttpClient Function() _clientFactory;
  final Future<Directory> Function() _documentsDirectory;
  final Duration requestTimeout;
  final Duration downloadTimeout;
  final int maxFirmwareBytes;
  HttpClient? _client;
  bool _closed = false;
  bool _downloading = false;

  Future<SavedFirmware> loginAndDownload({
    required String username,
    required String password,
    void Function(double?)? onProgress,
  }) async {
    _ensureOpen();
    if (_downloading) {
      throw const FlowFirmwareException(
        'A firmware download is already running.',
      );
    }
    if (username.trim().isEmpty || password.isEmpty) {
      throw const FlowFirmwareException(
        'Enter your email address and password.',
      );
    }
    _downloading = true;
    HttpClient? client;
    File? partialFile;
    try {
      final directory = await _firmwareDirectory();
      _ensureOpen();
      client = _clientFactory();
      _client = client;
      client.connectionTimeout = requestTimeout;
      // A ZIP is already compressed. Keeping the wire bytes makes the size
      // limit and Content-Length checks independent of HTTP decompression.
      client.autoUncompress = false;
      onProgress?.call(null);
      final token = await _authenticate(client, username.trim(), password);
      _ensureOpen();
      final response = await _downloadResponse(client, token);
      if (response.contentLength > maxFirmwareBytes) {
        throw const FlowFirmwareException('The firmware package is too large.');
      }
      final name =
          '$_filenamePrefix${DateTime.now().toUtc().microsecondsSinceEpoch}'
          '-${Random.secure().nextInt(1 << 32).toRadixString(16)}.zip';
      final finalFile = File('${directory.path}${Platform.pathSeparator}$name');
      partialFile = File('${finalFile.path}.part');
      await _saveResponse(response, partialFile, onProgress);
      _ensureOpen();
      if (!await _isFirmwareZip(partialFile)) {
        throw const FlowFirmwareException(
          'The server did not return a valid firmware ZIP with extractable '
          '.bin and .dat files.',
        );
      }
      _ensureOpen();
      // A unique destination preserves previous packages, including a package
      // that may already have been selected for an update. Renaming on the
      // same filesystem exposes only a completely downloaded file.
      await partialFile.rename(finalFile.path);
      partialFile = null;
      onProgress?.call(1);
      return SavedFirmware(path: finalFile.path, name: name);
    } on FlowFirmwareException {
      rethrow;
    } on TimeoutException {
      throw FlowFirmwareException(
        _closed
            ? 'Download cancelled.'
            : 'The request timed out. Please try again.',
      );
    } on FileSystemException {
      throw const FlowFirmwareException(
        'Could not save the firmware on this device. Check available storage.',
      );
    } on SocketException {
      throw FlowFirmwareException(
        _closed
            ? 'Download cancelled.'
            : 'Could not connect to Flow. Check your connection and try again.',
      );
    } on HandshakeException {
      throw const FlowFirmwareException(
        'Could not establish a secure connection to Flow.',
      );
    } on HttpException {
      throw FlowFirmwareException(
        _closed
            ? 'Download cancelled.'
            : 'The download was interrupted. Please try again.',
      );
    } catch (_) {
      // Native storage and network errors can contain URLs or response details.
      // They must not reach the UI, logs, or persistent storage.
      throw FlowFirmwareException(
        _closed
            ? 'Download cancelled.'
            : 'Could not download the firmware. Please try again.',
      );
    } finally {
      client?.close(force: true);
      if (identical(_client, client)) _client = null;
      _downloading = false;
      if (partialFile != null) {
        try {
          if (await partialFile.exists()) await partialFile.delete();
        } on FileSystemException {
          // A failed cleanup must not hide the original error. Partial files
          // are never offered by loadSavedFirmware().
        }
      }
    }
  }

  /// Returns the latest complete package, including after an app restart.
  Future<SavedFirmware?> loadSavedFirmware() async {
    _ensureOpen();
    try {
      final directory = await _firmwareDirectory();
      final files = await directory
          .list()
          .where((entity) {
            if (entity is! File) return false;
            final name = entity.uri.pathSegments.last;
            return name.startsWith(_filenamePrefix) && name.endsWith('.zip');
          })
          .cast<File>()
          .toList();
      // The timestamp in each app-generated filename sorts chronologically.
      files.sort((a, b) => b.path.compareTo(a.path));
      for (final file in files) {
        _ensureOpen();
        if (await _isFirmwareZip(file)) {
          _ensureOpen();
          return SavedFirmware(
            path: file.path,
            name: file.uri.pathSegments.last,
          );
        }
      }
      if (files.isNotEmpty) {
        throw const FlowFirmwareException(
          'Saved firmware is not a valid firmware ZIP containing .bin and .dat '
          'files. Download it again.',
        );
      }
      return null;
    } on FlowFirmwareException {
      rethrow;
    } catch (_) {
      throw const FlowFirmwareException(
        'Could not read firmware saved on this device.',
      );
    }
  }

  /// Cancels the active network request and disposes this screen's service.
  void close() {
    _closed = true;
    _client?.close(force: true);
  }

  void _ensureOpen() {
    if (_closed) throw const FlowFirmwareException('Download cancelled.');
  }

  Future<Directory> _firmwareDirectory() async {
    final documents = await _documentsDirectory();
    _ensureOpen();
    return Directory(
      '${documents.path}${Platform.pathSeparator}flow-firmware',
    ).create(recursive: true);
  }

  Future<String> _authenticate(
    HttpClient client,
    String username,
    String password,
  ) async {
    final request = await client.postUrl(_authUri).timeout(requestTimeout);
    _ensureOpen();
    // Never repeat a POST containing credentials at a redirect target.
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.add(
      utf8.encode(jsonEncode({'username': username, 'password': password})),
    );
    final response = await request.close().timeout(requestTimeout);
    _ensureOpen();
    if ([400, 401, 403].contains(response.statusCode)) {
      throw const FlowFirmwareException(
        'Login failed. Check your email address and password.',
      );
    }
    if (response.statusCode != HttpStatus.ok) {
      throw FlowFirmwareException(
        'Flow login failed (HTTP ${response.statusCode}).',
      );
    }
    final bytes = BytesBuilder(copy: false);
    await (() async {
      await for (final chunk in response) {
        _ensureOpen();
        if (bytes.length + chunk.length > 64 * 1024) {
          throw const FlowFirmwareException(
            'Flow returned an invalid login response.',
          );
        }
        bytes.add(chunk);
      }
    })().timeout(requestTimeout);
    try {
      final body = jsonDecode(utf8.decode(bytes.takeBytes()));
      final token = body is Map<String, dynamic> ? body['token'] : null;
      if (token is! String || token.isEmpty || RegExp(r'\s').hasMatch(token)) {
        throw const FormatException();
      }
      return token;
    } on FormatException {
      throw const FlowFirmwareException(
        'Flow returned an invalid login response.',
      );
    }
  }

  Future<HttpClientResponse> _downloadResponse(
    HttpClient client,
    String token,
  ) async {
    var uri = _firmwareUri;
    for (var redirects = 0; redirects <= 5; redirects++) {
      _ensureOpen();
      final request = await client.getUrl(uri).timeout(requestTimeout);
      _ensureOpen();
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/zip, application/octet-stream',
      );
      if (uri.origin == _firmwareUri.origin) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Token $token');
      }
      final response = await request.close().timeout(requestTimeout);
      _ensureOpen();
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || redirects == 5) {
          throw const FlowFirmwareException(
            'Flow returned an invalid download redirect.',
          );
        }
        final next = uri.resolve(location);
        if (next.scheme != 'https' ||
            next.host.isEmpty ||
            next.userInfo.isNotEmpty) {
          throw const FlowFirmwareException(
            'Flow returned an insecure download redirect.',
          );
        }
        // Cancel this body before following the redirect, without downloading
        // arbitrary redirect content. HttpClient opens a fresh connection when
        // this response's connection cannot be reused.
        await response.listen((_) {}).cancel();
        uri = next;
        continue;
      }
      if ([401, 403].contains(response.statusCode)) {
        throw const FlowFirmwareException(
          'Your Flow account cannot access this firmware.',
        );
      }
      if (response.statusCode != HttpStatus.ok) {
        throw FlowFirmwareException(
          'Firmware download failed (HTTP ${response.statusCode}).',
        );
      }
      return response;
    }
    throw const FlowFirmwareException(
      'Flow returned too many download redirects.',
    );
  }

  Future<void> _saveResponse(
    HttpClientResponse response,
    File file,
    void Function(double?)? onProgress,
  ) async {
    final output = await file.open(mode: FileMode.write);
    var received = 0;
    final expected = response.contentLength;
    final stopwatch = Stopwatch()..start();
    final iterator = StreamIterator(response.timeout(requestTimeout));
    try {
      while (true) {
        _ensureOpen();
        final remaining = downloadTimeout - stopwatch.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('Firmware transfer');
        }
        if (!await iterator.moveNext().timeout(remaining)) break;
        final chunk = iterator.current;
        received += chunk.length;
        if (received > maxFirmwareBytes) {
          throw const FlowFirmwareException(
            'The firmware package is too large.',
          );
        }
        _ensureOpen();
        await output.writeFrom(chunk);
        // Completion is reported only once validation and the atomic save pass.
        onProgress?.call(
          expected > 0 ? (received / expected).clamp(0.0, 0.99) : null,
        );
      }
      if (expected >= 0 && received != expected) {
        throw const FlowFirmwareException(
          'The download was incomplete. Please try again.',
        );
      }
      await output.flush();
    } finally {
      await iterator.cancel();
      await output.close();
    }
  }

  Future<bool> _isFirmwareZip(File file) async {
    if (!await _hasZipEnvelope(file)) return false;
    _ensureOpen();
    final path = file.path;
    final limit = maxFirmwareBytes;
    // Decompression and checksums must not block the UI or its STOP control.
    // Only a path and limit cross the isolate boundary, never account details.
    return Isolate.run(() => _verifyFirmwareContents(path, limit));
  }

  /// Reject incomplete directories before asking the decoder to read entries.
  Future<bool> _hasZipEnvelope(File file) async {
    final length = await file.length();
    if (length < 30 + 46 + 22 || length > maxFirmwareBytes) return false;
    final input = await file.open();
    try {
      final start = await input.read(4);
      if (!_signature(start, 0, 0x04034b50)) return false;
      final tailLength = min(length, 65535 + 22);
      await input.setPosition(length - tailLength);
      final tail = await input.read(tailLength);
      final data = ByteData.sublistView(tail);
      for (var offset = tail.length - 22; offset >= 0; offset--) {
        if (!_signature(tail, offset, 0x06054b50)) continue;
        final commentLength = data.getUint16(offset + 20, Endian.little);
        if (offset + 22 + commentLength != tail.length) continue;
        final entries = data.getUint16(offset + 10, Endian.little);
        final directoryLength = data.getUint32(offset + 12, Endian.little);
        final directoryOffset = data.getUint32(offset + 16, Endian.little);
        if (data.getUint16(offset + 4, Endian.little) != 0 ||
            data.getUint16(offset + 6, Endian.little) != 0 ||
            data.getUint16(offset + 8, Endian.little) != entries ||
            entries == 0 ||
            entries > 4096 ||
            directoryOffset + directoryLength != length - tailLength + offset ||
            directoryLength < 46) {
          return false;
        }
        await input.setPosition(directoryOffset);
        return _signature(await input.read(4), 0, 0x02014b50);
      }
      return false;
    } finally {
      await input.close();
    }
  }

  bool _signature(List<int> bytes, int offset, int signature) {
    if (bytes.length < offset + 4) return false;
    return bytes[offset] == signature & 0xff &&
        bytes[offset + 1] == (signature >> 8) & 0xff &&
        bytes[offset + 2] == (signature >> 16) & 0xff &&
        bytes[offset + 3] == (signature >> 24) & 0xff;
  }
}

/// Read every entry to prove it can be extracted, without writing archive paths
/// to disk. Device compatibility and signature validation remain with Nordic DFU.
bool _verifyFirmwareContents(String path, int maxExpandedBytes) {
  final input = InputFileStream(path);
  try {
    final directory = ZipDirectory()..read(input);
    if (directory.fileHeaders.length !=
        directory.totalCentralDirectoryEntries) {
      return false;
    }
    var totalSize = 0;
    var hasBin = false;
    var hasDat = false;
    for (final header in directory.fileHeaders) {
      final entry = header.file;
      if (entry == null ||
          entry.filename != header.filename ||
          entry.flags != header.generalPurposeBitFlag ||
          entry.flags & 1 != 0 ||
          ![0, 8, 12, 93].contains(header.compressionMethod)) {
        return false;
      }
      // Reject unsupported or contradictory compression headers; unknown
      // methods otherwise fall back to stored bytes in the archive decoder.
      final localHeader = input.subset(position: header.localHeaderOffset);
      if (localHeader.readUint32() != ZipFile.zipSignature) return false;
      localHeader.skip(4);
      if (localHeader.readUint16() != header.compressionMethod) return false;
      localHeader.skip(4);
      final localCrc = localHeader.readUint32();
      final localCompressedSize = localHeader.readUint32();
      final localExpandedSize = localHeader.readUint32();
      final nameLength = localHeader.readUint16();
      final extraLength = localHeader.readUint16();
      final contentEnd =
          header.localHeaderOffset +
          30 +
          nameLength +
          extraLength +
          header.compressedSize;
      if (contentEnd > directory.centralDirectoryOffset ||
          header.diskNumberStart != 0) {
        return false;
      }
      // Streaming ZIP writers put these values in a data descriptor instead.
      // The decoder checks its CRC below but ignores descriptor sizes, which
      // sequential ZIP readers need to agree with the extracted data too.
      if (entry.flags & 8 != 0) {
        localHeader.skip(nameLength);
        final extra = localHeader.readBytes(extraLength);
        var zip64 = false;
        while (extra.length >= 4) {
          final id = extra.readUint16();
          final size = extra.readUint16();
          if (size > extra.length) return false;
          if (id == 1) zip64 = true;
          extra.skip(size);
        }
        final descriptor = input.subset(
          position: contentEnd,
          length: directory.centralDirectoryOffset - contentEnd,
        );
        if (descriptor.length < 4) return false;
        final signatureOrCrc = descriptor.readUint32();
        final signed = signatureOrCrc == 0x08074b50;
        if (descriptor.length < (signed ? 4 : 0) + (zip64 ? 16 : 8)) {
          return false;
        }
        final descriptorCrc = signed ? descriptor.readUint32() : signatureOrCrc;
        final descriptorCompressed = zip64
            ? descriptor.readUint64()
            : descriptor.readUint32();
        final descriptorExpanded = zip64
            ? descriptor.readUint64()
            : descriptor.readUint32();
        if (descriptorCrc != header.crc32 ||
            descriptorCompressed != header.compressedSize ||
            descriptorExpanded != header.uncompressedSize) {
          return false;
        }
      } else if (localCrc != header.crc32 ||
          (localCompressedSize != header.compressedSize &&
              localCompressedSize != 0xffffffff) ||
          (localExpandedSize != header.uncompressedSize &&
              localExpandedSize != 0xffffffff)) {
        return false;
      }

      totalSize += entry.uncompressedSize;
      if (entry.uncompressedSize < 0 || totalSize > maxExpandedBytes) {
        return false;
      }
      // ZipFile bounds decompression to its declared size. Compare the actual
      // size as well, and explicitly check CRC: ZipDecoder.verify is ignored.
      final bytes = entry.getStream().toUint8List();
      final crc = getCrc32(bytes);
      if (bytes.length != entry.uncompressedSize ||
          crc != entry.crc32 ||
          crc != header.crc32) {
        return false;
      }
      final name = entry.filename.toLowerCase();
      final unixType = (header.externalFileAttributes >> 16) & 0xf000;
      final isDirectory =
          name.endsWith('/') ||
          name.endsWith('\\') ||
          header.externalFileAttributes & 0x10 != 0 ||
          unixType == 0x4000;
      // Directories and symbolic links named *.bin / *.dat are not firmware.
      final isFile = !isDirectory && (unixType == 0 || unixType == 0x8000);
      if (isFile && bytes.isNotEmpty) {
        hasBin |= name.endsWith('.bin');
        hasDat |= name.endsWith('.dat');
      }
    }
    return hasBin && hasDat;
  } catch (_) {
    // Parser and decompressor errors may include remote entry names or data.
    return false;
  } finally {
    input.closeSync();
  }
}
