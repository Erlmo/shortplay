/// 红果 ProgressRateInfo 的已使用字段，时间单位均为毫秒。
class PlaybackReportBook {
  const PlaybackReportBook({
    required this.bookId,
    required this.itemId,
    required this.currentPlayTime,
    required this.cumulativeDuration,
    required this.readTimestampMs,
    required this.vidIndex,
  });

  final String bookId;
  final String itemId;
  final int currentPlayTime;
  final int cumulativeDuration;
  final int readTimestampMs;
  final int vidIndex;

  static final _idPattern = RegExp(r'^[1-9][0-9]{0,31}$');

  static bool validId(String value) {
    final match = _idPattern.firstMatch(value);
    return match != null && match.end == value.length;
  }

  Map<String, dynamic> toJson() => {
        'book_id': bookId,
        'item_id': itemId,
        'book_type': 2,
        'current_play_time': currentPlayTime,
        'player_cumulative_total_duration': cumulativeDuration,
        'read_timestamp_ms': readTimestampMs,
        'vid_index': vidIndex,
        'is_listen_mode': false,
      };

  factory PlaybackReportBook.fromJson(Map<String, dynamic> json) {
    final bookId = json['book_id'];
    final itemId = json['item_id'];
    final position = json['current_play_time'];
    final cumulative = json['player_cumulative_total_duration'];
    final timestamp = json['read_timestamp_ms'];
    final index = json['vid_index'];
    if (bookId is! String ||
        !validId(bookId) ||
        itemId is! String ||
        !validId(itemId) ||
        position is! int ||
        position < 0 ||
        cumulative is! int ||
        cumulative < 0 ||
        timestamp is! int ||
        timestamp < 1 ||
        index is! int ||
        index < 1 ||
        json['book_type'] != 2 ||
        json['is_listen_mode'] != false) {
      throw const FormatException('观看记录格式无效');
    }
    return PlaybackReportBook(
      bookId: bookId,
      itemId: itemId,
      currentPlayTime: position,
      cumulativeDuration: cumulative,
      readTimestampMs: timestamp,
      vidIndex: index,
    );
  }
}
