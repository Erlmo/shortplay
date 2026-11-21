import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Shared on-disk format used by the Dart downloader and native IO adapters.
/// The bytes remain in their original encrypted/clear form; decoding is external.
class MediaCacheStore {
  MediaCacheStore(
    this.directory, {
    this.maxBytes = 300 * 1024 * 1024,
    this.maxAge = const Duration(hours: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    directory.createSync(recursive: true);
  }

  static const blockSize = 32768;
  final Directory directory;
  final int maxBytes;
  final Duration maxAge;
  final DateTime Function() _clock;
  int cacheBytesRead = 0;
  int cacheBytesWritten = 0;
  int corruptBlocks = 0;
  int writeFailures = 0;
  int _sequence = 0;

  /// 异步写入时两次磁盘清理的最小间隔。
  static const pruneInterval = Duration(seconds: 30);
  DateTime? _lastAsyncPrune;

  static String identity(String url) =>
      sha256.convert(utf8.encode(url)).toString();
  Directory _object(String url) =>
      Directory('${directory.path}/${identity(url)}');
  File _block(String url, int index) =>
      File('${_object(url).path}/blocks/$index.blk');

  DateTime get now => _clock();

  MediaCacheMetadata? metadata(String url) {
    try {
      final file = File('${_object(url).path}/meta.json');
      if (file.lengthSync() > 16384) return null;
      final value = jsonDecode(file.readAsStringSync());
      if (value is! Map || value['version'] != 1) return null;
      final total = value['totalLength'];
      final expires = value['expiresAt'];
      if (total is! int ||
          total <= 0 ||
          expires is! num ||
          !expires.isFinite ||
          expires > 8640000000000000 ||
          expires <= _clock().millisecondsSinceEpoch) {
        return null;
      }
      return MediaCacheMetadata(
          total,
          DateTime.fromMillisecondsSinceEpoch(expires.toInt()),
          value['etag'] as String?);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// A missing block is a cache miss, never an invented EOF or zero-filled data.
  Uint8List? read(String url, int start, int end) {
    final meta = metadata(url);
    if (meta == null || start < 0 || end < start) return null;
    if (start >= meta.totalLength) return Uint8List(0);
    final wanted = math.min(end + 1, meta.totalLength) - start;
    final prefix = readPrefix(url, start, wanted);
    return prefix != null && prefix.length == wanted ? prefix : null;
  }

  Uint8List? readPrefix(String url, int start, int maxLength) {
    final meta = metadata(url);
    if (meta == null || start < 0 || maxLength <= 0) return null;
    if (start >= meta.totalLength) return Uint8List(0);
    final end = math.min(start + maxLength, meta.totalLength);
    final builder = BytesBuilder(copy: false);
    var position = start;
    while (position < end) {
      final block = _readBlock(url, position ~/ blockSize, meta);
      if (block == null) break;
      final offset = position % blockSize;
      final count = math.min(block.length - offset, end - position);
      if (count <= 0) break;
      builder.add(Uint8List.sublistView(block, offset, offset + count));
      position += count;
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) return null;
    cacheBytesRead += bytes.length;
    return bytes;
  }

  Uint8List? _readBlock(String url, int index, MediaCacheMetadata meta,
      {bool touch = true}) {
    final file = _block(url, index);
    try {
      final expected =
          math.min(blockSize, meta.totalLength - index * blockSize);
      if (expected <= 0 || file.lengthSync() != expected + 32) return null;
      final bytes = file.readAsBytesSync();
      final payload = Uint8List.sublistView(bytes, 32);
      final digest = sha256.convert(payload).bytes;
      for (var n = 0; n < 32; n++) {
        if (bytes[n] != digest[n]) {
          corruptBlocks++;
          try {
            file.deleteSync();
          } on FileSystemException {/* Native reader may race eviction. */}
          return null;
        }
      }
      try {
        if (touch) file.setLastModifiedSync(_clock());
      } on FileSystemException {/* Read is still valid. */}
      return payload;
    } on FileSystemException {
      return null;
    }
  }

  /// 在后台线程读取并校验一段已缓存的开头数据（同 [readPrefix]），
  /// 避免逐块计算 SHA-256 占住界面线程导致掉帧。
  Future<Uint8List?> readPrefixAsync(
      String url, int start, int maxLength) async {
    final root = directory.path;
    final budget = maxBytes;
    final age = maxAge;
    final timestamp = now;
    try {
      final result = await Isolate.run(() {
        final store = MediaCacheStore(Directory(root),
            maxBytes: budget, maxAge: age, clock: () => timestamp);
        final bytes = store.readPrefix(url, start, maxLength);
        return (
          bytes == null ? null : TransferableTypedData.fromList([bytes]),
          store.cacheBytesRead,
          store.corruptBlocks,
        );
      }, debugName: 'media-cache-read');
      cacheBytesRead += result.$2;
      corruptBlocks += result.$3;
      return result.$1?.materialize().asUint8List();
    } catch (_) {
      return null;
    }
  }

  /// 在后台线程统计已缓存的范围（同 [inspect]，会逐块校验，数据多时很耗时）。
  Future<MediaCacheInfo> inspectAsync(String url) async {
    final root = directory.path;
    final budget = maxBytes;
    final age = maxAge;
    final timestamp = now;
    try {
      return await Isolate.run(() {
        final store = MediaCacheStore(Directory(root),
            maxBytes: budget, maxAge: age, clock: () => timestamp);
        return store.inspect(url);
      }, debugName: 'media-cache-inspect');
    } catch (_) {
      return const MediaCacheInfo(0, 0, []);
    }
  }

  /// Only complete verified blocks are published. Temp files never represent
  /// cached bytes. A cancelled transfer can still contribute completed blocks.
  void write(
    String url,
    int offset,
    List<int> bytes, {
    required int totalLength,
    String? etag,
    DateTime? expiresAt,
    bool pruneAfterWrite = true,
  }) {
    if (maxBytes == 0 ||
        totalLength <= 0 ||
        offset < 0 ||
        bytes.isEmpty ||
        offset + bytes.length > totalLength) {
      return;
    }
    try {
      var old = metadata(url);
      if (old == null && _object(url).existsSync()) invalidate(url);
      if (old != null &&
          (old.totalLength != totalLength ||
              (old.etag != null && etag != null && old.etag != etag))) {
        invalidate(url);
        old = null;
      }
      final expiry = expiresAt ?? old?.expiresAt ?? _clock().add(maxAge);
      if (!expiry.isAfter(_clock())) return;
      final object = _object(url);
      Directory('${object.path}/blocks').createSync(recursive: true);
      final meta = utf8.encode(jsonEncode({
        'version': 1,
        'totalLength': totalLength,
        'expiresAt': expiry.millisecondsSinceEpoch,
        'etag': etag ?? old?.etag,
      }));
      _atomicWrite(File('${object.path}/meta.json'), meta);
      final first = (offset + blockSize - 1) ~/ blockSize;
      for (var index = first;
          index * blockSize < offset + bytes.length;
          index++) {
        final begin = index * blockSize;
        final length = math.min(blockSize, totalLength - begin);
        if (begin + length > offset + bytes.length) break;
        final payload = Uint8List.fromList(
            bytes.sublist(begin - offset, begin - offset + length));
        final file = _block(url, index);
        _atomicWrite(file, [...sha256.convert(payload).bytes, ...payload]);
        file.setLastModifiedSync(_clock());
        cacheBytesWritten += length;
      }
      if (pruneAfterWrite) prune();
    } on FileSystemException {
      // Cache storage is expendable; callers still receive verified live data.
    }
  }

  /// File flushing and eviction run off the UI isolate. Keep the synchronous
  /// format API available for native interoperability fixtures and tooling.
  Future<void> writeAsync(
    String url,
    int offset,
    Uint8List bytes, {
    required int totalLength,
    String? etag,
    DateTime? expiresAt,
  }) async {
    final root = directory.path;
    final budget = maxBytes;
    final age = maxAge;
    final timestamp = now;
    // 播放时预加载会频繁写入，每次写完都全盘清理会让 CPU 持续高负载导致发热，
    // 所以最多每 pruneInterval 清理一次；系统时间被往回调时也照常清理。
    final last = _lastAsyncPrune;
    final pruneNow =
        last == null || timestamp.difference(last).abs() >= pruneInterval;
    if (pruneNow) _lastAsyncPrune = timestamp;
    final data = TransferableTypedData.fromList([bytes]);
    try {
      final written = await Isolate.run(() {
        final store = MediaCacheStore(Directory(root),
            maxBytes: budget, maxAge: age, clock: () => timestamp);
        store.write(url, offset, data.materialize().asUint8List(),
            totalLength: totalLength,
            etag: etag,
            expiresAt: expiresAt,
            pruneAfterWrite: pruneNow);
        return store.cacheBytesWritten;
      }, debugName: 'media-cache-commit');
      cacheBytesWritten += written;
    } catch (_) {
      // Disk full, permissions or worker startup must not fail live playback.
      writeFailures++;
    }
  }

  void _atomicWrite(File file, List<int> bytes) {
    final temporary = File(
        '${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(0x7fffffff)}-${_sequence++}');
    try {
      temporary.writeAsBytesSync(bytes, flush: true);
      temporary.renameSync(file.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  /// A positive cache probe verifies one real block, without scanning the full
  /// payload as inspect() does. Metadata alone is never counted as media.
  bool hasVerifiedMedia(String url) {
    final meta = metadata(url);
    if (meta == null) return false;
    try {
      final blocks = Directory('${_object(url).path}/blocks');
      for (final file in blocks.listSync(followLinks: false)) {
        if (file is! File) continue;
        final match =
            RegExp(r'^(\d+)\.blk$').firstMatch(file.uri.pathSegments.last);
        final index = match == null ? null : int.tryParse(match[1]!);
        if (index == null ||
            index >= (meta.totalLength + blockSize - 1) ~/ blockSize) {
          continue;
        }
        final block = _readBlock(url, index, meta, touch: false);
        if (block != null && block.isNotEmpty) return true;
      }
    } on FileSystemException {
      // Concurrent native cache eviction is a normal miss.
    }
    return false;
  }

  MediaCacheInfo inspect(String url) {
    final meta = metadata(url);
    if (meta == null) return const MediaCacheInfo(0, 0, []);
    final ranges = <MediaCachedRange>[];
    var prefix = 0;
    final indexes = <int>[];
    try {
      final blocks = Directory('${_object(url).path}/blocks');
      for (final file in blocks.listSync(followLinks: false)) {
        if (file is! File) continue;
        final name = file.uri.pathSegments.last;
        final match = RegExp(r'^(\d+)\.blk$').firstMatch(name);
        if (match != null) indexes.add(int.parse(match[1]!));
      }
    } on FileSystemException {
      return MediaCacheInfo(meta.totalLength, 0, const []);
    }
    indexes.sort();
    for (final index in indexes) {
      final block = _readBlock(url, index, meta, touch: false);
      if (block == null) continue;
      final start = index * blockSize;
      if (start == prefix) prefix += block.length;
      if (ranges.isNotEmpty && ranges.last.end == start) {
        final last = ranges.removeLast();
        ranges.add(MediaCachedRange(last.start, start + block.length));
      } else {
        ranges.add(MediaCachedRange(start, start + block.length));
      }
    }
    return MediaCacheInfo(meta.totalLength, prefix, List.unmodifiable(ranges));
  }

  void invalidate(String url) {
    final object = _object(url);
    try {
      if (object.existsSync()) object.deleteSync(recursive: true);
    } on FileSystemException {/* Concurrent native cache eviction. */}
  }

  /// Our explicit disk policy. The official demo's 300MiB budget is evidence;
  /// this block-mtime eviction algorithm is ours, not claimed MDL pseudocode.
  void prune() {
    try {
      // 每个文件只读取一次大小和修改时间，排序时直接用已读到的值。
      // 以前在排序比较里反复读修改时间，缓存满（约 9600 个块）时一轮清理要
      // 几十万次磁盘查询，播放中持续占用 CPU。
      final blocks = <(File, int, DateTime)>[];
      var total = 0;
      for (final entity
          in directory.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final stat = entity.statSync();
        // 文件可能刚被原生端淘汰，跳过即可。
        if (stat.type == FileSystemEntityType.notFound) continue;
        total += stat.size;
        if (entity.path.endsWith('.blk')) {
          blocks.add((entity, stat.size, stat.modified));
        }
      }
      if (total <= maxBytes) return;
      blocks.sort((a, b) => a.$3.compareTo(b.$3));
      for (final (block, size, _) in blocks) {
        try {
          block.deleteSync();
        } on FileSystemException {
          // 已被并发删除的块不计入释放量，继续淘汰下一个。
          continue;
        }
        total -= size;
        if (total <= maxBytes) break;
      }
    } on FileSystemException {/* 原生端读写或淘汰可能与本次清理并发。 */}
  }
}

class MediaCacheMetadata {
  const MediaCacheMetadata(this.totalLength, this.expiresAt, this.etag);
  final int totalLength;
  final DateTime expiresAt;
  final String? etag;
}

class MediaCachedRange {
  const MediaCachedRange(this.start, this.end);
  final int start;
  final int end; // Exclusive.
}

class MediaCacheInfo {
  const MediaCacheInfo(this.totalLength, this.cachedBytesFromZero, this.ranges);
  final int totalLength;
  final int cachedBytesFromZero;
  final List<MediaCachedRange> ranges;
  int get cachedBytes =>
      ranges.fold(0, (sum, range) => sum + range.end - range.start);
}
