class PlaybackRecord {
  const PlaybackRecord({
    required this.dramaId,
    required this.dramaName,
    required this.cover,
    required this.episodeIndex,
    required this.positionMs,
    required this.updatedAtMs,
    this.episodeNumber,
  });

  final int dramaId;
  final String dramaName;
  final String cover;
  final int episodeIndex;
  final int? episodeNumber;
  final int positionMs;
  final int updatedAtMs;

  Map<String, dynamic> toJson() => {
        'dramaId': dramaId,
        'dramaName': dramaName,
        'cover': cover,
        'episodeIndex': episodeIndex,
        if (episodeNumber != null) 'episodeNumber': episodeNumber,
        'positionMs': positionMs,
        'updatedAtMs': updatedAtMs,
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
    );
  }
}
