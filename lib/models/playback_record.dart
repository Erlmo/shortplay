class PlaybackRecord {
  const PlaybackRecord({
    required this.dramaId,
    required this.dramaName,
    required this.cover,
    required this.episodeIndex,
    required this.positionMs,
    required this.updatedAtMs,
    this.episodeNumber,
    this.durationMs,
    this.episodeCount,
  });

  final int dramaId;
  final String dramaName;
  final String cover;
  final int episodeIndex;
  final int? episodeNumber;
  final int positionMs;
  final int updatedAtMs;

  /// 当前这一集的总时长（毫秒），用于显示单集进度；旧记录没有。
  final int? durationMs;

  /// 这一季的总集数；旧记录没有。
  final int? episodeCount;

  /// 当前集的观看进度 0~1；没有时长信息时为 null。
  double? get episodeProgress {
    final d = durationMs;
    if (d == null || d <= 0) return null;
    return (positionMs / d).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'dramaId': dramaId,
        'dramaName': dramaName,
        'cover': cover,
        'episodeIndex': episodeIndex,
        if (episodeNumber != null) 'episodeNumber': episodeNumber,
        'positionMs': positionMs,
        'updatedAtMs': updatedAtMs,
        if (durationMs != null) 'durationMs': durationMs,
        if (episodeCount != null) 'episodeCount': episodeCount,
      };

  factory PlaybackRecord.fromJson(Map<String, dynamic> json) {
    return PlaybackRecord(
      dramaId: json['dramaId'] is int
          ? json['dramaId'] as int
          : int.tryParse(json['dramaId']?.toString() ?? '') ?? 0,
      dramaName: json['dramaName']?.toString() ?? '',
      cover: json['cover']?.toString() ?? '',
      episodeIndex: json['episodeIndex'] is int
          ? json['episodeIndex'] as int
          : int.tryParse(json['episodeIndex']?.toString() ?? '') ?? 0,
      episodeNumber: json['episodeNumber'] is int
          ? json['episodeNumber'] as int
          : int.tryParse(json['episodeNumber']?.toString() ?? ''),
      positionMs: json['positionMs'] is int
          ? json['positionMs'] as int
          : int.tryParse(json['positionMs']?.toString() ?? '') ?? 0,
      updatedAtMs: json['updatedAtMs'] is int
          ? json['updatedAtMs'] as int
          : int.tryParse(json['updatedAtMs']?.toString() ?? '') ?? 0,
      durationMs: _optInt(json['durationMs']),
      episodeCount: _optInt(json['episodeCount']),
    );
  }

  static int? _optInt(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }
}
