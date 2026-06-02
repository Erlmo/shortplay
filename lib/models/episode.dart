class Episode {
  Episode({
    required this.index,
    required this.name,
    required this.size,
    required this.url,
  });

  final int index;
  final String name;
  final int size;
  final String url;

  String get readableSize {
    if (size <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    var remaining = size.toDouble();
    var unitIndex = 0;
    while (remaining >= 1024 && unitIndex < units.length - 1) {
      remaining /= 1024;
      unitIndex++;
    }
    return '${remaining.toStringAsFixed(remaining >= 10 ? 0 : 1)}${units[unitIndex]}';
  }

  factory Episode.fromJson(Map<String, dynamic> json) {
    final sizeValue = json['size'];
    final parsedSize = sizeValue is int
        ? sizeValue
        : int.tryParse(sizeValue?.toString() ?? '') ?? 0;
    return Episode(
      index: json['index'] is int
          ? json['index'] as int
          : int.tryParse(json['index']?.toString() ?? '') ?? 0,
      name: json['name']?.toString() ?? '',
      size: parsedSize,
      url: json['url']?.toString() ?? '',
    );
  }
}
