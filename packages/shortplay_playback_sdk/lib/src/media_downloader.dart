import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'first_frame.dart';
import 'media_cache.dart';
import 'network_routes.dart';

class MediaRangeException implements Exception {
  const MediaRangeException(this.message,
      {this.retryable = false, this.rangeUnsupported = false, this.statusCode});
  final String message;
  final bool retryable;
  final int? statusCode;
  final bool rangeUnsupported;
  @override
  String toString() => 'MediaRangeException: $message';
}

class MediaReadResult {
  const MediaReadResult(this.bytes, this.totalLength,
      {this.rangeSupported = true});
  final Uint8List bytes;
  final int totalLength;
  final bool rangeSupported;
}

/// Bounded, direct-CDN HTTP downloader. Playback's native adapters read/write
/// the same raw byte store. There is no localhost server or decryption here.
class MediaDownloader {
  MediaDownloader(
    this.cache, {
    HttpClient? client,
    this.maxConcurrent = 1,
    this.maxAttempts = 3,
    this.readTimeout = const Duration(seconds: 5),
  }) : _client = client ?? HttpClient() {
    if (maxConcurrent < 1 || maxAttempts < 1) {
      throw ArgumentError('Invalid download limits');
    }
    _client.autoUncompress = false;
    _client.connectionTimeout = readTimeout;
  }

  final MediaCacheStore cache;
  final HttpClient _client;
  final int maxConcurrent;
  final int maxAttempts;
  final Duration readTimeout;
  final _flights = <String, List<_Transfer>>{};
  final _waiters = Queue<Completer<void>>();
  int _active = 0;
  bool _closed = false;
  int networkRequests = 0;
  int networkBytes = 0;
  int sharedTransfers = 0;
  final routes = MediaRouteRegistry();

  void registerSource(String primary, Iterable<String> candidates,
          {DateTime? expiresAt}) =>
      routes.register(primary, candidates, expiresAt: expiresAt);

  String activeSourceUrl(String primary) =>
      routes.lookup(primary)?.activeUrl ?? primary;

  Future<MediaReadResult> readRange(
    String url,
    int start,
    int end, {
    PlaybackCancellation? cancellation,
    DateTime? expiresAt,
  }) async {
    final token = cancellation ?? PlaybackCancellation();
    token.check();
    final route = routes.lookup(url);
    if (route == null || route.urls.length == 1) {
      return _readOneRange(url, start, end,
          cancellation: token, expiresAt: expiresAt);
    }
    // Anchor only verified bytes. Different CDN URLs keep independent caches.
    if (route.prefixHash == null) {
      final meta = cache.metadata(route.activeUrl);
      final length = meta == null ? 0 : math.min(32768, meta.totalLength);
      final prefix =
          length > 0 ? cache.read(route.activeUrl, 0, length - 1) : null;
      if (prefix != null && prefix.length == length) {
        route.totalLength = meta!.totalLength;
        route.prefixLength = length;
        route.prefixHash = sha256.convert(prefix).toString();
        route.delivered = true;
      }
    }
    Object? last;
    final choices = route.orderedUrls().toList();
    for (final candidate in choices) {
      token.check();
      try {
        if (candidate != route.activeUrl && route.delivered) {
          if (route.prefixHash == null) {
            throw const MediaRangeException('缺少媒体身份锚点，不能中途切换CDN');
          }
          final check = await _readOneRange(
              candidate, 0, route.prefixLength - 1,
              cancellation: token, expiresAt: expiresAt, attempts: 1);
          if (check.totalLength != route.totalLength ||
              sha256.convert(check.bytes).toString() != route.prefixHash) {
            cache.invalidate(candidate);
            throw const MediaRangeException('备用CDN媒体内容不一致');
          }
        }
        // An unsuccessful range is not exposed to the caller. A candidate
        // switch restarts this bounded range, never splices its partial body.
        final data = await _readOneRange(candidate, start, end,
            cancellation: token, expiresAt: expiresAt, attempts: 1);
        if (route.totalLength != null &&
            route.totalLength != data.totalLength) {
          cache.invalidate(candidate);
          throw const MediaRangeException('备用CDN媒体长度不一致');
        }
        route.totalLength = data.totalLength;
        if (start == 0 &&
            data.bytes.length >= math.min(32768, data.totalLength)) {
          final length = math.min(32768, data.totalLength);
          route.prefixLength = length;
          route.prefixHash =
              sha256.convert(data.bytes.sublist(0, length)).toString();
        }
        route.delivered = true;
        route.activeUrl = candidate;
        return data;
      } on PlaybackCancelled {
        rethrow;
      } on Object catch (error) {
        token.check();
        final http = error is MediaRangeException && error.statusCode != null;
        final transient = error is SocketException ||
            error is HttpException ||
            error is TimeoutException ||
            (error is MediaRangeException && error.retryable);
        if (!http && !transient) rethrow;
        last = error;
      }
    }
    throw last ?? const MediaRangeException('当前媒体的CDN候选均不可用');
  }

  Future<MediaReadResult> _readOneRange(
    String url,
    int start,
    int end, {
    PlaybackCancellation? cancellation,
    DateTime? expiresAt,
    int? attempts,
  }) async {
    final token = cancellation ?? PlaybackCancellation();
    token.check();
    if (_closed) throw StateError('媒体下载器已关闭');
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        start < 0 ||
        end < start ||
        end - start >= 8 * 1024 * 1024) {
      throw ArgumentError('无效的媒体读取范围');
    }
    final output = BytesBuilder(copy: false);
    var cursor = start;
    var rangeSupported = true;
    int? total = cache.metadata(url)?.totalLength;
    while (cursor <= end && (total == null || cursor < total)) {
      token.check();
      final cached = cache.readPrefix(url, cursor, end - cursor + 1);
      if (cached != null && cached.isNotEmpty) {
        output.add(cached);
        cursor += cached.length;
        total = cache.metadata(url)?.totalLength ?? total;
        continue;
      }
      final key = MediaCacheStore.identity(url);
      final transfers = _flights[key] ?? const <_Transfer>[];
      _Transfer? shared;
      for (final transfer in transfers) {
        if (!transfer.cancel.isCancelled &&
            transfer.end >= cursor &&
            transfer.start <= end) {
          shared = transfer;
          break;
        }
      }
      if (shared != null) {
        sharedTransfers++;
        final data = await _lease(shared, token);
        total = data.totalLength;
        rangeSupported = rangeSupported && data.rangeSupported;
        // A covering transfer can be used even when the disk quota is smaller
        // than the requested range. Partial overlaps are picked up from cache.
        if (shared.start <= cursor && shared.end >= cursor) {
          final offset = cursor - shared.start;
          final n = math.min(data.bytes.length - offset, end - cursor + 1);
          if (n > 0) {
            output.add(Uint8List.sublistView(data.bytes, offset, offset + n));
            cursor += n;
          }
        }
        continue;
      }
      final alignedStart =
          cursor ~/ MediaCacheStore.blockSize * MediaCacheStore.blockSize;
      var alignedEnd = ((math.min(end, cursor + 1024 * 1024 - 1) +
                      1 +
                      MediaCacheStore.blockSize -
                      1) ~/
                  MediaCacheStore.blockSize) *
              MediaCacheStore.blockSize -
          1;
      if (total != null) alignedEnd = math.min(alignedEnd, total - 1);
      // Do not re-fetch a cached suffix just because the prefix has a hole.
      for (var base = alignedStart + MediaCacheStore.blockSize;
          base <= alignedEnd;
          base += MediaCacheStore.blockSize) {
        if (cache.read(url, base,
                math.min(base + MediaCacheStore.blockSize - 1, alignedEnd)) !=
            null) {
          alignedEnd = base - 1;
          break;
        }
      }
      final transfer = _Transfer(
          url, alignedStart, alignedEnd, expiresAt, attempts ?? maxAttempts);
      (_flights[key] ??= []).add(transfer);
      final lease = _lease(transfer, token);
      unawaited(_perform(transfer, key));
      final data = await lease;
      total = data.totalLength;
      rangeSupported = rangeSupported && data.rangeSupported;
      final offset = cursor - alignedStart;
      final count = math.min(data.bytes.length - offset, end - cursor + 1);
      if (count <= 0) {
        if (cursor >= total) break;
        throw const MediaRangeException('媒体响应没有推进读取位置');
      }
      output.add(Uint8List.sublistView(data.bytes, offset, offset + count));
      cursor += count;
    }
    token.check();
    return MediaReadResult(output.takeBytes(), total ?? start,
        rangeSupported: rangeSupported);
  }

  Future<MediaCacheInfo> prefetch(
    String url, {
    int bytes = 800 * 1024,
    PlaybackCancellation? cancellation,
    DateTime? expiresAt,
  }) async {
    if (bytes <= 0) throw ArgumentError.value(bytes, 'bytes');
    var cursor = 0;
    while (cursor < bytes) {
      final result = await readRange(
          url, cursor, math.min(cursor + 1024 * 1024, bytes) - 1,
          cancellation: cancellation, expiresAt: expiresAt);
      cursor += result.bytes.length;
      if (cursor >= result.totalLength || result.bytes.isEmpty) break;
    }
    return cache.inspect(activeSourceUrl(url));
  }

  /// Writes a caller-owned temporary file. It is only renamed by the caller
  /// after its own task-generation and media validity checks have succeeded.
  Future<int> downloadToFile(
    String url,
    File temporary, {
    PlaybackCancellation? cancellation,
    void Function(int received, int total)? onProgress,
  }) async {
    final token = cancellation ?? PlaybackCancellation();
    token.check();
    temporary.parent.createSync(recursive: true);
    final file = await temporary.open(mode: FileMode.write);
    var position = 0;
    try {
      while (true) {
        MediaReadResult data;
        try {
          data = await readRange(url, position, position + 1024 * 1024 - 1,
              cancellation: token);
        } on MediaRangeException catch (error) {
          if (!error.rangeUnsupported) rethrow;
          await file.truncate(0);
          await file.setPosition(0);
          return await _downloadSequentialRoutes(url, file, token, onProgress);
        }
        token.check();
        if (!data.rangeSupported && data.bytes.length < data.totalLength) {
          await file.truncate(0);
          await file.setPosition(0);
          return await _downloadSequentialRoutes(url, file, token, onProgress);
        }
        if (data.bytes.isEmpty && position < data.totalLength) {
          throw const MediaRangeException('媒体文件提前结束');
        }
        await file.writeFrom(data.bytes);
        position += data.bytes.length;
        onProgress?.call(position, data.totalLength);
        if (position >= data.totalLength) break;
      }
      token.check();
      await file.flush();
      return position;
    } finally {
      await file.close();
    }
  }

  Future<int> _downloadSequentialRoutes(String primary, RandomAccessFile file,
      PlaybackCancellation token, void Function(int, int)? onProgress) async {
    final route = routes.lookup(primary);
    final urls = route?.orderedUrls().toList() ?? [primary];
    Object? last;
    for (final candidate in urls) {
      token.check();
      try {
        if (route != null && route.delivered && candidate != route.activeUrl) {
          if (route.prefixHash == null) {
            throw const MediaRangeException('缺少媒体身份锚点，不能切换CDN');
          }
          final check = await _readOneRange(
              candidate, 0, route.prefixLength - 1,
              cancellation: token, attempts: 1);
          if (check.totalLength != route.totalLength ||
              sha256.convert(check.bytes).toString() != route.prefixHash) {
            cache.invalidate(candidate);
            throw const MediaRangeException('备用CDN媒体内容不一致');
          }
        }
        await file.truncate(0);
        await file.setPosition(0);
        final count =
            await _downloadSequential(candidate, file, token, onProgress);
        if (route != null) route.activeUrl = candidate;
        return count;
      } on PlaybackCancelled {
        rethrow;
      } on Object catch (error) {
        token.check();
        final http = error is MediaRangeException && error.statusCode != null;
        final transient = error is SocketException ||
            error is HttpException ||
            error is TimeoutException ||
            (error is MediaRangeException && error.retryable);
        if (!http && !transient) rethrow;
        last = error;
      }
    }
    throw last ?? const MediaRangeException('完整媒体下载失败');
  }

  Future<int> _downloadSequential(String url, RandomAccessFile file,
      PlaybackCancellation token, void Function(int, int)? onProgress) async {
    await _acquire();
    HttpClientRequest? request;
    StreamIterator<List<int>>? body;
    try {
      token.check();
      final opening = _client.getUrl(Uri.parse(url)).timeout(readTimeout);
      unawaited(opening.then<void>((value) {
        if (token.isCancelled) value.abort(const PlaybackCancelled());
      }, onError: (Object _, StackTrace __) {}));
      final activeRequest = await token.wait(opening);
      request = activeRequest;
      activeRequest.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      networkRequests++;
      final response =
          await token.wait(activeRequest.close().timeout(readTimeout));
      if (response.statusCode != 200) {
        throw MediaRangeException('CDN完整下载响应无效 (${response.statusCode})',
            statusCode: response.statusCode);
      }
      if ((response.headers.value(HttpHeaders.contentEncodingHeader) ??
                  'identity')
              .toLowerCase() !=
          'identity') {
        throw const MediaRangeException('CDN完整下载响应被压缩');
      }
      final total = response.contentLength;
      var count = 0;
      body = StreamIterator(response);
      while (await token.wait(body.moveNext().timeout(readTimeout))) {
        token.check();
        await file.writeFrom(body.current);
        count += body.current.length;
        networkBytes += body.current.length;
        onProgress?.call(count, total);
      }
      token.check();
      if (count == 0 || (total >= 0 && count != total)) {
        throw const MediaRangeException('完整下载的媒体长度不匹配');
      }
      await file.flush();
      return count;
    } finally {
      await body?.cancel();
      request?.abort();
      _release();
    }
  }

  Future<MediaReadResult> _lease(
      _Transfer transfer, PlaybackCancellation token) async {
    token.check();
    transfer.users++;
    try {
      return await token.wait(transfer.done.future);
    } finally {
      transfer.users--;
      if (transfer.users == 0 && !transfer.done.isCompleted) {
        transfer.cancel.cancel();
        transfer.request?.abort(const PlaybackCancelled());
      }
    }
  }

  Future<void> _acquire() async {
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _active--;
    }
  }

  Future<void> _perform(_Transfer transfer, String key) async {
    await _acquire();
    try {
      transfer.cancel.check();
      final result = await _fetch(transfer);
      transfer.cancel.check();
      transfer.done.complete(result);
    } catch (error, stack) {
      transfer.done.completeError(error, stack);
    } finally {
      _flights[key]?.remove(transfer);
      if (_flights[key]?.isEmpty == true) _flights.remove(key);
      _release();
    }
  }

  Future<MediaReadResult> _fetch(_Transfer transfer) async {
    final chunks = <List<int>>[];
    var received = 0;
    final anchored = cache.metadata(transfer.url);
    int? total = anchored?.totalLength;
    String? etag = anchored?.etag;
    Object? lastError;
    for (var attempt = 0; attempt < transfer.maxAttempts; attempt++) {
      transfer.cancel.check();
      StreamIterator<List<int>>? iterator;
      var verifiedRange = false;
      try {
        final offset = transfer.start + received;
        final opening =
            _client.getUrl(Uri.parse(transfer.url)).timeout(readTimeout);
        unawaited(opening.then<void>((request) {
          if (transfer.cancel.isCancelled) {
            request.abort(const PlaybackCancelled());
          }
        }, onError: (Object _, StackTrace __) {}));
        final request = await transfer.cancel.wait(opening);
        transfer.request = request;
        if (transfer.cancel.isCancelled) {
          request.abort();
          throw const PlaybackCancelled();
        }
        request.headers
            .set(HttpHeaders.rangeHeader, 'bytes=$offset-${transfer.end}');
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        networkRequests++;
        final response =
            await transfer.cancel.wait(request.close().timeout(readTimeout));
        final encoding =
            response.headers.value(HttpHeaders.contentEncodingHeader);
        if (encoding != null && encoding.toLowerCase() != 'identity') {
          throw const MediaRangeException('CDN返回了压缩后的媒体字节');
        }
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw MediaRangeException('CDN HTTP ${response.statusCode}',
              statusCode: response.statusCode,
              retryable: response.statusCode >= 500 ||
                  response.statusCode == 408 ||
                  response.statusCode == 429);
        }
        int responseTotal;
        int responseEnd;
        if (response.statusCode == 206) {
          final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
              response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
          if (range == null) {
            throw const MediaRangeException('CDN缺少有效Content-Range');
          }
          final actualStart = int.parse(range[1]!);
          responseEnd = int.parse(range[2]!);
          responseTotal = int.parse(range[3]!);
          if (actualStart != offset ||
              responseTotal <= actualStart ||
              responseEnd < actualStart ||
              responseEnd > math.min(transfer.end, responseTotal - 1) ||
              (response.contentLength >= 0 &&
                  response.contentLength != responseEnd - offset + 1)) {
            throw const MediaRangeException('CDN返回的字节范围不匹配');
          }
        } else {
          if (offset != 0 || response.contentLength <= 0) {
            throw const MediaRangeException('CDN忽略了非零偏移的Range请求',
                rangeUnsupported: true);
          }
          responseTotal = response.contentLength;
          responseEnd = math.min(transfer.end, responseTotal - 1);
        }
        final validator = response.headers.value(HttpHeaders.etagHeader);
        if (total != null &&
            (total != responseTotal ||
                (etag != null && validator != null && etag != validator))) {
          cache.invalidate(transfer.url);
          chunks.clear();
          received = 0;
          total = null;
          etag = null;
          throw const MediaRangeException('续传时媒体内容已经变化');
        }
        total = responseTotal;
        etag ??= validator;
        verifiedRange = response.statusCode == 206;
        final required = responseEnd - transfer.start + 1;
        iterator = StreamIterator(response);
        while (received < required) {
          final next = await transfer.cancel
              .wait(iterator.moveNext().timeout(readTimeout));
          if (!next) {
            throw const MediaRangeException('CDN媒体响应提前结束', retryable: true);
          }
          final data = iterator.current;
          final count = math.min(data.length, required - received);
          if (count <= 0) continue;
          chunks.add(Uint8List.fromList(data.sublist(0, count)));
          received += count;
          networkBytes += count;
        }
        if (verifiedRange &&
            transfer.start + received < math.min(transfer.end + 1, total)) {
          // A valid shorter 206 is progress, not an error or EOF. Continue from
          // its actual end without spending the failure retry allowance.
          attempt--;
          continue;
        }
        final bytes = _join(chunks);
        return MediaReadResult(bytes, total, rangeSupported: verifiedRange);
      } on PlaybackCancelled {
        rethrow;
      } on Object catch (error) {
        lastError = error;
        if (transfer.cancel.isCancelled) throw const PlaybackCancelled();
        final retryable = error is SocketException ||
            error is HttpException ||
            error is TimeoutException ||
            (error is MediaRangeException && error.retryable);
        if (!retryable || attempt + 1 >= transfer.maxAttempts) rethrow;
        await transfer.cancel.wait(
            Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1))));
      } finally {
        await iterator?.cancel();
        transfer.request?.abort();
        transfer.request = null;
        // Complete blocks survive an interrupted transfer, not partial data.
        if (verifiedRange && received > 0 && total != null) {
          await cache.writeAsync(transfer.url, transfer.start, _join(chunks),
              totalLength: total, etag: etag, expiresAt: transfer.expiresAt);
        }
      }
    }
    throw lastError ?? const MediaRangeException('媒体请求失败');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final list in _flights.values) {
      for (final transfer in list) {
        transfer.cancel.cancel();
        transfer.request?.abort(const PlaybackCancelled());
      }
    }
    _client.close(force: true);
  }
}

class _Transfer {
  _Transfer(this.url, this.start, this.end, this.expiresAt, this.maxAttempts);
  final int maxAttempts;
  final String url;
  final int start;
  final int end;
  final DateTime? expiresAt;
  final cancel = PlaybackCancellation();
  final done = Completer<MediaReadResult>();
  HttpClientRequest? request;
  int users = 0;
}

Uint8List _join(List<List<int>> chunks) {
  final builder = BytesBuilder(copy: false);
  for (final chunk in chunks) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}
