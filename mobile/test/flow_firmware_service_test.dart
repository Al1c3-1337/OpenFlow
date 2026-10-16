import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openflow/src/flow_firmware_service.dart';

void main() {
  late Directory documents;
  late _Client client;
  late FlowFirmwareService service;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp(
      'openflow-firmware-test-',
    );
    client = _Client();
    service = FlowFirmwareService(
      clientFactory: () => client,
      documentsDirectory: () async => documents,
      requestTimeout: const Duration(milliseconds: 300),
      downloadTimeout: const Duration(seconds: 2),
    );
  });

  tearDown(() async {
    service.close();
    await documents.delete(recursive: true);
  });

  Future<SavedFirmware> download({void Function(double?)? onProgress}) =>
      service.loginAndDownload(
        username: ' person@example.com ',
        password: 'password with spaces ',
        onProgress: onProgress,
      );

  void queueSuccess() {
    client.responses.addAll([
      _Response.json({'token': 'secret-token'}),
      _Response.bytes(_zip()),
    ]);
  }

  test('authenticates and saves the authenticated ZIP durably', () async {
    queueSuccess();
    final progress = <double?>[];
    final saved = await download(onProgress: progress.add);

    expect(client.requests, hasLength(2));
    final auth = client.requests[0];
    expect(auth.method, 'POST');
    expect(
      auth.uri.toString(),
      'https://api.flowneuroscience.com/api/v2/auth/',
    );
    expect(auth.followRedirects, isFalse);
    expect(auth.headers.contentType, ContentType.json);
    expect(auth.headers.value(HttpHeaders.acceptEncodingHeader), 'identity');
    expect(jsonDecode(utf8.decode(auth.body)), {
      'username': 'person@example.com',
      'password': 'password with spaces ',
    });
    expect(auth.headers.values[HttpHeaders.authorizationHeader], isNull);
    final firmware = client.requests[1];
    expect(firmware.method, 'GET');
    expect(
      firmware.uri.toString(),
      'https://api.flowneuroscience.com/api/v2/firmware/8548778e-f6d6-4571-8eda-f6a7e4e0e7bc/',
    );
    expect(
      firmware.headers.values[HttpHeaders.authorizationHeader],
      'Token secret-token',
    );
    expect(
      firmware.headers.value(HttpHeaders.acceptEncodingHeader),
      'identity',
    );
    expect(await File(saved.path).readAsBytes(), _zip());
    final extracted = ZipDecoder().decodeBytes(
      await File(saved.path).readAsBytes(),
    );
    expect(extracted.findFile(_binName)?.content, _firmwareFiles[_binName]);
    expect(extracted.findFile(_datName)?.content, _firmwareFiles[_datName]);
    expect(extracted.findFile(_binName)?.compression, CompressionType.deflate);
    expect(
      saved.path,
      contains('${documents.path}${Platform.pathSeparator}flow-firmware'),
    );
    expect(saved.name, endsWith('.zip'));
    expect(progress.first, isNull);
    expect(progress.last, 1);
    expect(progress.where((value) => value == 1), hasLength(1));
    expect(progress.take(progress.length - 1), isNot(contains(1)));
    expect(client.closed, isTrue);
    expect(
      (await documents.list(recursive: true).toList()).whereType<File>(),
      hasLength(1),
    );

    // A new service discovers the file without logging in or storing a token.
    final reopened = FlowFirmwareService(
      documentsDirectory: () async => documents,
    );
    expect((await reopened.loadSavedFirmware())?.path, saved.path);
    reopened.close();
  });

  test(
    'incorrect credentials never request firmware or persist response details',
    () async {
      client.responses.add(
        _Response.json({'detail': 'secret-password'}, statusCode: 400),
      );
      await expectLater(
        download(),
        throwsA(
          isA<FlowFirmwareException>()
              .having(
                (error) => error.message,
                'message',
                contains('Login failed'),
              )
              .having(
                (error) => error.toString(),
                'sanitized message',
                isNot(contains('secret-password')),
              ),
        ),
      );
      expect(client.requests, hasLength(1));
      expect(await service.loadSavedFirmware(), isNull);
    },
  );

  test(
    'a malformed or missing token fails before requesting firmware',
    () async {
      for (final token in [null, '', 'token\r\ninjection']) {
        client.responses.add(_Response.json({'token': token}));
        await expectLater(
          download(),
          throwsA(
            isA<FlowFirmwareException>().having(
              (error) => error.message,
              'message',
              contains('invalid login response'),
            ),
          ),
        );
      }
      expect(client.requests, hasLength(3));
    },
  );

  test('does not send credentials to a login redirect', () async {
    client.responses.add(
      _Response.bytes(
        [],
        statusCode: 307,
        location: 'https://other.example/login',
      ),
    );
    await expectLater(download(), throwsA(isA<FlowFirmwareException>()));
    expect(client.requests, hasLength(1));
    expect(client.requests.single.followRedirects, isFalse);
  });

  test(
    'follows HTTPS downloads but keeps the token on the API origin',
    () async {
      client.responses.addAll([
        _Response.json({'token': 'secret-token'}),
        _Response.bytes([], statusCode: 302, location: '/download.zip'),
        _Response.bytes(
          [],
          statusCode: 302,
          location: 'https://files.example/firmware.zip?signature=123',
        ),
        _Response.bytes(_zip()),
      ]);
      await download();
      expect(
        client.requests[2].headers.values[HttpHeaders.authorizationHeader],
        'Token secret-token',
      );
      expect(
        client.requests[3].headers.values[HttpHeaders.authorizationHeader],
        isNull,
      );
      expect(
        client.requests.skip(1).every((request) => !request.followRedirects),
        isTrue,
      );
    },
  );

  test('rejects insecure and embedded-credential redirects', () async {
    for (final location in [
      'http://files.example/firmware.zip',
      'https://user:pass@files.example/file',
    ]) {
      client.responses.addAll([
        _Response.json({'token': 'secret-token'}),
        _Response.bytes([], statusCode: 302, location: location),
      ]);
      await expectLater(
        download(),
        throwsA(
          isA<FlowFirmwareException>().having(
            (error) => error.message,
            'message',
            contains('insecure download redirect'),
          ),
        ),
      );
    }
    expect(client.requests, hasLength(4));
  });

  test(
    'rejects JSON and truncated ZIPs, preserving an earlier package',
    () async {
      queueSuccess();
      final saved = await download();
      for (final invalid in [
        utf8.encode('{"detail":"not a ZIP"}'),
        _zip().sublist(0, _zip().length - 1),
      ]) {
        client.responses.addAll([
          _Response.json({'token': 'secret-token'}),
          _Response.bytes(invalid),
        ]);
        await expectLater(
          download(),
          throwsA(
            isA<FlowFirmwareException>().having(
              (error) => error.message,
              'message',
              contains('valid firmware ZIP'),
            ),
          ),
        );
      }
      expect((await service.loadSavedFirmware())?.path, saved.path);
      expect(await File(saved.path).readAsBytes(), _zip());
      expect(
        (await documents.list(recursive: true).toList()).whereType<File>(),
        hasLength(1),
      );
    },
  );

  test('rejects declared oversized files before writing any bytes', () async {
    client.responses.addAll([
      _Response.json({'token': 'secret-token'}),
      _Response.bytes([], contentLength: 65 * 1024 * 1024),
    ]);
    await expectLater(
      download(),
      throwsA(
        isA<FlowFirmwareException>().having(
          (error) => error.message,
          'message',
          contains('too large'),
        ),
      ),
    );
    expect(
      (await documents.list(recursive: true).toList()).whereType<File>(),
      isEmpty,
    );
  });

  final invalidPackages = <String, Uint8List Function()>{
    'missing BIN': () => _zip(files: Map.of(_firmwareFiles)..remove(_binName)),
    'missing DAT': () => _zip(files: Map.of(_firmwareFiles)..remove(_datName)),
    'empty BIN': () => _zip(files: {..._firmwareFiles, _binName: []}),
    'empty DAT': () => _zip(files: {..._firmwareFiles, _datName: []}),
    'BIN directory': () => _zip(
      files: Map.of(_firmwareFiles)..remove(_binName),
      directories: [_binName],
    ),
    'DAT directory': () => _zip(
      files: Map.of(_firmwareFiles)..remove(_datName),
      directories: [_datName],
    ),
    'corrupt BIN payload': () => _mutatedZip(_binName, (bytes, data, entry) {
      bytes[entry.data] ^= 0xff;
    }, compress: false),
    'corrupt manifest payload': () =>
        _mutatedZip('manifest.json', (bytes, data, entry) {
          bytes[entry.data] ^= 0xff;
        }, compress: false),
    'malformed deflate stream': () =>
        _mutatedZip(_binName, (bytes, data, entry) {
          // BTYPE=11 is a reserved, invalid deflate block type.
          bytes[entry.data] = (bytes[entry.data] & 0xf8) | 7;
        }),
    'forged uncompressed size': () =>
        _mutatedZip(_binName, (bytes, data, entry) {
          final forged = _firmwareFiles[_binName]!.length + 1;
          data.setUint32(entry.local + 22, forged, Endian.little);
          data.setUint32(entry.central + 24, forged, Endian.little);
        }),
    'truncated compressed entry': () =>
        _mutatedZip(_binName, (bytes, data, entry) {
          final forged = entry.compressedSize ~/ 2;
          data.setUint32(entry.local + 18, forged, Endian.little);
          data.setUint32(entry.central + 20, forged, Endian.little);
        }),
    'entry outside the archive': () =>
        _mutatedZip(_binName, (bytes, data, entry) {
          data.setUint32(entry.central + 42, bytes.length + 100, Endian.little);
        }),
    'encrypted package': () => _zip(password: 'test-only-password'),
  };

  for (final invalid in invalidPackages.entries) {
    test(
      'rejects ${invalid.key} before completion and preserves saved firmware',
      () async {
        queueSuccess();
        final previous = await download();
        client.responses.addAll([
          _Response.json({'token': 'secret-token'}),
          _Response.bytes(invalid.value()),
        ]);
        final progress = <double?>[];
        await expectLater(
          download(onProgress: progress.add),
          throwsA(
            isA<FlowFirmwareException>().having(
              (error) => error.message,
              'message',
              contains('valid firmware ZIP'),
            ),
          ),
        );
        expect(progress, isNot(contains(1)));
        expect((await service.loadSavedFirmware())?.path, previous.path);
        expect(await File(previous.path).readAsBytes(), _zip());
        expect(
          (await documents.list(recursive: true).toList()).whereType<File>(),
          hasLength(1),
        );
      },
    );
  }

  for (final zip64 in [false, true]) {
    for (final signature in [false, true]) {
      final descriptorType =
          '${zip64 ? '64' : '32'}-bit '
          '${signature ? 'signed' : 'signatureless'} data descriptor';
      test('accepts a streaming ZIP with $descriptorType', () async {
        final archive = _streamingZip(signature: signature, zip64: zip64);
        client.responses.addAll([
          _Response.json({'token': 'secret-token'}),
          _Response.bytes(archive),
        ]);
        final progress = <double?>[];
        final saved = await download(onProgress: progress.add);
        final extracted = ZipDecoder().decodeBytes(
          await File(saved.path).readAsBytes(),
        );
        expect(extracted.findFile(_binName)?.content, _firmwareFiles[_binName]);
        expect(extracted.findFile(_datName)?.content, _firmwareFiles[_datName]);
        expect(progress.last, 1);
      });

      for (final field in ['CRC', 'compressed size', 'expanded size']) {
        test('rejects corrupt $field in a $descriptorType', () async {
          queueSuccess();
          final previous = await download();
          final archive = _mutatedZip(_binName, (bytes, data, entry) {
            final descriptor =
                entry.data + entry.compressedSize + (signature ? 4 : 0);
            if (field == 'CRC') {
              data.setUint32(
                descriptor,
                data.getUint32(descriptor, Endian.little) ^ 1,
                Endian.little,
              );
              return;
            }
            final sizeOffset =
                descriptor +
                4 +
                (field == 'expanded size' ? (zip64 ? 8 : 4) : 0);
            if (zip64) {
              data.setUint64(
                sizeOffset,
                data.getUint64(sizeOffset, Endian.little) + 1,
                Endian.little,
              );
            } else {
              data.setUint32(
                sizeOffset,
                data.getUint32(sizeOffset, Endian.little) + 1,
                Endian.little,
              );
            }
          }, source: _streamingZip(signature: signature, zip64: zip64));
          client.responses.addAll([
            _Response.json({'token': 'secret-token'}),
            _Response.bytes(archive),
          ]);
          final progress = <double?>[];
          await expectLater(
            download(onProgress: progress.add),
            throwsA(
              isA<FlowFirmwareException>().having(
                (error) => error.message,
                'message',
                contains('valid firmware ZIP'),
              ),
            ),
          );
          expect(progress, isNot(contains(1)));
          expect((await service.loadSavedFirmware())?.path, previous.path);
          expect(
            (await documents.list(recursive: true).toList()).whereType<File>(),
            hasLength(1),
          );
        });
      }
    }
  }

  test('limits expanded ZIP contents as well as download size', () async {
    service.close();
    service = FlowFirmwareService(
      clientFactory: () => client,
      documentsDirectory: () async => documents,
      maxFirmwareBytes: 1024,
    );
    final compressed = _zip();
    expect(compressed.length, lessThan(1024));
    expect(_firmwareFiles[_binName]!.length, greaterThan(1024));
    client.responses.addAll([
      _Response.json({'token': 'secret-token'}),
      _Response.bytes(compressed),
    ]);
    await expectLater(download(), throwsA(isA<FlowFirmwareException>()));
    expect(
      (await documents.list(recursive: true).toList()).whereType<File>(),
      isEmpty,
    );
  });

  test(
    'enforces the size limit for a response without Content-Length',
    () async {
      service.close();
      service = FlowFirmwareService(
        clientFactory: () => client,
        documentsDirectory: () async => documents,
        maxFirmwareBytes: 100,
      );
      client.responses.addAll([
        _Response.json({'token': 'secret-token'}),
        _Response.bytes(_zip(), contentLength: -1),
      ]);
      await expectLater(
        download(),
        throwsA(
          isA<FlowFirmwareException>().having(
            (error) => error.message,
            'message',
            contains('too large'),
          ),
        ),
      );
      expect(
        (await documents.list(recursive: true).toList()).whereType<File>(),
        isEmpty,
      );
    },
  );

  test('incomplete transfers clean their partial files', () async {
    client.responses.addAll([
      _Response.json({'token': 'secret-token'}),
      _Response.bytes(_zip(), contentLength: _zip().length + 1),
    ]);
    await expectLater(
      download(),
      throwsA(
        isA<FlowFirmwareException>().having(
          (error) => error.message,
          'message',
          contains('incomplete'),
        ),
      ),
    );
    expect(
      (await documents.list(recursive: true).toList()).whereType<File>(),
      isEmpty,
    );
  });

  test('a stalled transfer times out and removes its partial file', () async {
    final body = StreamController<List<int>>();
    client.responses.addAll([
      _Response.json({'token': 'secret-token'}),
      _Response(body.stream),
    ]);
    await expectLater(
      download(),
      throwsA(
        isA<FlowFirmwareException>().having(
          (error) => error.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
    await body.close();
    expect(
      (await documents.list(recursive: true).toList()).whereType<File>(),
      isEmpty,
    );
    expect(client.closed, isTrue);
  });

  test(
    'closing a screen cancels the transfer without saving its partial file',
    () async {
      final body = StreamController<List<int>>();
      final reading = Completer<void>();
      body.onListen = reading.complete;
      client.onClose = () => body.addError(const HttpException('closed'));
      client.responses.addAll([
        _Response.json({'token': 'secret-token'}),
        _Response(body.stream),
      ]);
      final result = download();
      final failure = expectLater(
        result,
        throwsA(
          isA<FlowFirmwareException>().having(
            (error) => error.message,
            'message',
            'Download cancelled.',
          ),
        ),
      );
      await reading.future;
      service.close();
      await failure;
      await body.close();
      expect(
        (await documents.list(recursive: true).toList()).whereType<File>(),
        isEmpty,
      );
    },
  );

  test('ignores orphaned partial files', () async {
    final directory = await Directory(
      '${documents.path}${Platform.pathSeparator}flow-firmware',
    ).create();
    await File(
      '${directory.path}${Platform.pathSeparator}flow-firmware-8548778e-123.zip.part',
    ).writeAsBytes(_zip());
    expect(await service.loadSavedFirmware(), isNull);
  });

  test(
    'invalid saved firmware cannot bypass validation after reopening',
    () async {
      final directory = await Directory(
        '${documents.path}${Platform.pathSeparator}flow-firmware',
      ).create();
      await File(
        '${directory.path}${Platform.pathSeparator}flow-firmware-8548778e-9999999999999999.zip',
      ).writeAsBytes(_zip(files: Map.of(_firmwareFiles)..remove(_datName)));
      final reopened = FlowFirmwareService(
        documentsDirectory: () async => documents,
      );
      try {
        await expectLater(
          reopened.loadSavedFirmware(),
          throwsA(
            isA<FlowFirmwareException>().having(
              (error) => error.message,
              'message',
              allOf(contains('Saved firmware'), contains('.bin and .dat')),
            ),
          ),
        );
      } finally {
        reopened.close();
      }
    },
  );

  test(
    'reopening skips a corrupt newer saved package and restores the valid older package',
    () async {
      queueSuccess();
      final previous = await download();
      final directory = File(previous.path).parent;
      final corrupt = _mutatedZip('manifest.json', (bytes, data, entry) {
        bytes[entry.data] ^= 0xff;
      }, compress: false);
      await File(
        '${directory.path}${Platform.pathSeparator}flow-firmware-8548778e-9999999999999999.zip',
      ).writeAsBytes(corrupt);
      final reopened = FlowFirmwareService(
        documentsDirectory: () async => documents,
      );
      try {
        expect((await reopened.loadSavedFirmware())?.path, previous.path);
      } finally {
        reopened.close();
      }
    },
  );
}

class _Client extends Fake implements HttpClient {
  final responses = <_Response>[];
  final requests = <_Request>[];
  bool closed = false;
  void Function()? onClose;

  @override
  set connectionTimeout(Duration? value) {}

  @override
  set autoUncompress(bool value) {}

  Future<HttpClientRequest> _request(String method, Uri uri) async {
    // The fake can supply a fresh operation for sequential retry tests.
    closed = false;
    final request = _Request(method, uri, responses.removeAt(0));
    requests.add(request);
    return request;
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _request('POST', url);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _request('GET', url);

  @override
  void close({bool force = false}) {
    if (!closed) onClose?.call();
    closed = true;
  }
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.method, this.uri, this.response);

  @override
  final String method;
  @override
  final Uri uri;
  final _Response response;
  final body = <int>[];
  @override
  final _Headers headers = _Headers();
  @override
  bool followRedirects = true;

  @override
  void add(List<int> data) => body.addAll(data);

  @override
  Future<HttpClientResponse> close() async => response;
}

class _Headers extends Fake implements HttpHeaders {
  final values = <String, Object>{};
  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value;
  }

  @override
  String? value(String name) => values[name] as String?;
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(
    this.body, {
    this.statusCode = 200,
    this.contentLength = -1,
    String? location,
  }) {
    if (location != null) headers.values[HttpHeaders.locationHeader] = location;
  }

  factory _Response.bytes(
    List<int> bytes, {
    int statusCode = 200,
    int? contentLength,
    String? location,
  }) => _Response(
    Stream.value(bytes),
    statusCode: statusCode,
    contentLength: contentLength ?? bytes.length,
    location: location,
  );

  factory _Response.json(Object body, {int statusCode = 200}) =>
      _Response.bytes(utf8.encode(jsonEncode(body)), statusCode: statusCode);

  final Stream<List<int>> body;
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  final _Headers headers = _Headers();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _binName = 'application/HEADSET.BIN';
const _datName = 'metadata/Headset.DAT';
final _firmwareFiles = <String, List<int>>{
  _binName: List.generate(4096, (index) => index % 16),
  _datName: [1, 4, 8, 16, 32, 64, 128, 255],
  'manifest.json': utf8.encode(
    '{"manifest":{"application":{"bin_file":"$_binName","dat_file":"$_datName"}}}',
  ),
};

/// Deterministic real ZIP with deflated, nonempty firmware and metadata files.
Uint8List _zip({
  Map<String, List<int>>? files,
  List<String> directories = const [],
  String? password,
  bool compress = true,
}) {
  final archive = Archive();
  for (final file in (files ?? _firmwareFiles).entries) {
    archive.add(
      ArchiveFile.bytes(file.key, file.value)
        ..compression = compress
            ? CompressionType.deflate
            : CompressionType.none,
    );
  }
  for (final directory in directories) {
    archive.add(ArchiveFile.directory(directory));
  }
  return ZipEncoder(
    password: password,
  ).encodeBytes(archive, modified: DateTime.utc(2026, 1, 1));
}

typedef _EntryOffsets = ({
  int local,
  int central,
  int data,
  int compressedSize,
});

Uint8List _mutatedZip(
  String name,
  void Function(Uint8List, ByteData, _EntryOffsets) mutate, {
  bool compress = true,
  Uint8List? source,
}) {
  final bytes = source ?? _zip(compress: compress);
  final data = ByteData.sublistView(bytes);
  var central = data.getUint32(bytes.length - 22 + 16, Endian.little);
  while (data.getUint32(central, Endian.little) == 0x02014b50) {
    final nameLength = data.getUint16(central + 28, Endian.little);
    final entryName = utf8.decode(
      bytes.sublist(central + 46, central + 46 + nameLength),
    );
    if (entryName == name) {
      final local = data.getUint32(central + 42, Endian.little);
      final start =
          local +
          30 +
          data.getUint16(local + 26, Endian.little) +
          data.getUint16(local + 28, Endian.little);
      mutate(bytes, data, (
        local: local,
        central: central,
        data: start,
        compressedSize: data.getUint32(central + 20, Endian.little),
      ));
      return bytes;
    }
    central +=
        46 +
        nameLength +
        data.getUint16(central + 30, Endian.little) +
        data.getUint16(central + 32, Endian.little);
  }
  throw StateError('Fixture entry not found: $name');
}

/// Rewrites a normal fixture as a streaming ZIP: local sizes are unknown,
/// each compressed entry is followed by a descriptor, and the central
/// directory retains the complete metadata. ZIP64 here uses local extras and
/// wide descriptors; the small archive still has a normal end directory.
Uint8List _streamingZip({required bool signature, required bool zip64}) {
  final source = _zip();
  final data = ByteData.sublistView(source);
  final localFiles = BytesBuilder(copy: false);
  final centralHeaders = BytesBuilder(copy: false);
  var central = data.getUint32(source.length - 22 + 16, Endian.little);
  while (data.getUint32(central, Endian.little) == 0x02014b50) {
    final local = data.getUint32(central + 42, Endian.little);
    final nameLength = data.getUint16(local + 26, Endian.little);
    final extraLength = data.getUint16(local + 28, Endian.little);
    final originalHeaderLength = 30 + nameLength + extraLength;
    final compressed = data.getUint32(central + 20, Endian.little);
    final expanded = data.getUint32(central + 24, Endian.little);
    final crc = data.getUint32(central + 16, Endian.little);
    final newLocalOffset = localFiles.length;
    final localHeader = Uint8List(originalHeaderLength + (zip64 ? 20 : 0));
    localHeader.setRange(0, originalHeaderLength, source, local);
    final headerData = ByteData.sublistView(localHeader);
    headerData.setUint16(
      6,
      headerData.getUint16(6, Endian.little) | 8,
      Endian.little,
    );
    headerData.setUint32(14, 0, Endian.little);
    headerData.setUint32(18, zip64 ? 0xffffffff : 0, Endian.little);
    headerData.setUint32(22, zip64 ? 0xffffffff : 0, Endian.little);
    if (zip64) {
      headerData.setUint16(4, 45, Endian.little);
      headerData.setUint16(28, extraLength + 20, Endian.little);
      headerData.setUint16(originalHeaderLength, 1, Endian.little);
      headerData.setUint16(originalHeaderLength + 2, 16, Endian.little);
      // Both 64-bit sizes are unknown until the descriptor, so remain zero.
    }
    localFiles.add(localHeader);
    localFiles.add(
      Uint8List.sublistView(
        source,
        local + originalHeaderLength,
        local + originalHeaderLength + compressed,
      ),
    );
    final descriptor = Uint8List((signature ? 4 : 0) + 4 + (zip64 ? 16 : 8));
    final descriptorData = ByteData.sublistView(descriptor);
    var offset = 0;
    if (signature) {
      descriptorData.setUint32(0, 0x08074b50, Endian.little);
      offset = 4;
    }
    descriptorData.setUint32(offset, crc, Endian.little);
    if (zip64) {
      descriptorData.setUint64(offset + 4, compressed, Endian.little);
      descriptorData.setUint64(offset + 12, expanded, Endian.little);
    } else {
      descriptorData.setUint32(offset + 4, compressed, Endian.little);
      descriptorData.setUint32(offset + 8, expanded, Endian.little);
    }
    localFiles.add(descriptor);
    final centralLength =
        46 +
        data.getUint16(central + 28, Endian.little) +
        data.getUint16(central + 30, Endian.little) +
        data.getUint16(central + 32, Endian.little);
    final centralHeader = Uint8List.fromList(
      source.sublist(central, central + centralLength),
    );
    final centralData = ByteData.sublistView(centralHeader);
    centralData.setUint16(
      8,
      centralData.getUint16(8, Endian.little) | 8,
      Endian.little,
    );
    centralData.setUint32(42, newLocalOffset, Endian.little);
    if (zip64) centralData.setUint16(6, 45, Endian.little);
    centralHeaders.add(centralHeader);
    central += centralLength;
  }
  final end = Uint8List.fromList(source.sublist(source.length - 22));
  final endData = ByteData.sublistView(end);
  endData.setUint32(12, centralHeaders.length, Endian.little);
  endData.setUint32(16, localFiles.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(localFiles.takeBytes())
        ..add(centralHeaders.takeBytes())
        ..add(end))
      .takeBytes();
}
