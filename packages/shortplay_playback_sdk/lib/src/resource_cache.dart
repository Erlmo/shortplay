/// Bounded LRU metadata cache with single-flight loading. Clearing/replacing a
/// playlist invalidates pending insertions without cancelling a foreground
/// caller that still needs its result. Failed loads are never cached.
class PlaybackResourceCache<K, V> {
  PlaybackResourceCache({required this.capacity, required this.isValid}) {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
  }

  final int capacity;
  final bool Function(V value) isValid;
  final _values = <K, V>{};
  final _pending = <K, Future<V>>{};

  int get length => _values.length;

  V? get(K key) {
    final value = _values.remove(key);
    if (value == null || !isValid(value)) return null;
    _values[key] = value;
    return value;
  }

  Future<V> load(K key, Future<V> Function() loader) {
    final cached = get(key);
    if (cached != null) return Future.value(cached);
    final pending = _pending[key];
    if (pending != null) return pending;
    late final Future<V> request;
    request = Future<V>.sync(loader).then((value) {
      if (identical(_pending[key], request) && isValid(value)) {
        _values.remove(key);
        _values[key] = value;
        while (_values.length > capacity) {
          _values.remove(_values.keys.first);
        }
      }
      return value;
    }).whenComplete(() {
      if (identical(_pending[key], request)) _pending.remove(key);
    });
    _pending[key] = request;
    return request;
  }

  void retainWhere(bool Function(K key) keep) {
    _values.removeWhere((key, _) => !keep(key));
    _pending.removeWhere((key, _) => !keep(key));
  }

  void clear() {
    _values.clear();
    _pending.clear();
  }
}
