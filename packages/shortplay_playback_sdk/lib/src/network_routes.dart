/// Only URLs supplied for one media representation may be registered together.
/// No host rewriting, resolution fallback or decoder changes happen here.
List<String> mediaCandidateUrls(String primary, Iterable<String> candidates) {
  bool valid(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment;
  }

  if (!valid(primary)) throw ArgumentError('无效的主媒体地址');
  return List.unmodifiable(<String>{
    primary,
    ...candidates.where(valid),
  }.take(4));
}

class MediaSourceRoute {
  MediaSourceRoute(this.urls, this.expiresAt) : activeUrl = urls.first;
  final List<String> urls;
  final DateTime? expiresAt;
  String activeUrl;
  int? totalLength;
  String? prefixHash;
  int prefixLength = 0;
  bool delivered = false;

  Iterable<String> orderedUrls() sync* {
    yield activeUrl;
    yield* urls.where((url) => url != activeUrl);
  }
}

class MediaRouteRegistry {
  MediaRouteRegistry({this.capacity = 64, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
  }
  final int capacity;
  final DateTime Function() _clock;
  final _sources = <String, MediaSourceRoute>{};

  void register(String primary, Iterable<String> candidates,
      {DateTime? expiresAt}) {
    final urls = mediaCandidateUrls(primary, candidates);
    final old = _sources.remove(primary);
    final same = old != null &&
        old.urls.length == urls.length &&
        List.generate(urls.length, (i) => old.urls[i] == urls[i])
            .every((v) => v) &&
        old.expiresAt == expiresAt;
    _sources[primary] = same ? old : MediaSourceRoute(urls, expiresAt);
    while (_sources.length > capacity) {
      _sources.remove(_sources.keys.first);
    }
  }

  MediaSourceRoute? lookup(String primary) {
    final route = _sources.remove(primary);
    if (route == null) return null;
    if (route.expiresAt != null && !route.expiresAt!.isAfter(_clock())) {
      _sources[primary] = route;
      throw StateError('媒体地址已过期');
    }
    _sources[primary] = route;
    return route;
  }
}
