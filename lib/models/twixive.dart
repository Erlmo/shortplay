Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

String _text(Object? value) => value?.toString() ?? '';

String _webUrl(Object? value) {
  final text = _text(value);
  final uri = Uri.tryParse(text);
  return uri != null &&
          (uri.scheme == 'https' || uri.scheme == 'http') &&
          uri.host.isNotEmpty
      ? text
      : '';
}

class TwixiveUser {
  const TwixiveUser({
    required this.id,
    required this.username,
    required this.name,
    required this.avatar,
    this.followersCount = 0,
  });

  final String id;
  final String username;
  final String name;
  final String avatar;
  final int followersCount;

  String get label => name.isNotEmpty ? name : username;
  String get identifier => username.isNotEmpty ? username : id;

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'name': name,
        'avatar': avatar,
        'followersCount': followersCount,
      };

  factory TwixiveUser.fromJson(Map<String, dynamic> json) => TwixiveUser(
        id: _text(json['id']),
        username: _text(json['username']),
        name: _text(json['name']),
        avatar: _webUrl(json['avatar']),
        followersCount: int.tryParse(_text(json['followersCount'])) ?? 0,
      );
}

class TwixiveVideo {
  const TwixiveVideo({
    required this.id,
    required this.url,
    required this.thumbnail,
    required this.author,
    this.width = 0,
    this.height = 0,
  });

  final String id;
  final String url;
  final String thumbnail;
  final TwixiveUser author;
  final int width;
  final int height;

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'thumbnail': thumbnail,
        'author': author.toJson(),
        'width': width,
        'height': height,
      };

  factory TwixiveVideo.fromJson(Map<String, dynamic> json,
          {TwixiveUser? author}) =>
      TwixiveVideo(
        id: _text(json['id']),
        url: _webUrl(json['url']),
        thumbnail: _webUrl(json['thumbnail']),
        author: author ?? TwixiveUser.fromJson(_map(json['author'])),
        width: int.tryParse(_text(json['width'])) ?? 0,
        height: int.tryParse(_text(json['height'])) ?? 0,
      );
}

enum TwixiveFeed { home, latest, ranking, trending, users }

class TwixivePage {
  const TwixivePage({
    this.videos = const [],
    this.users = const [],
    this.user,
    this.nextCursor,
    required this.hasMore,
    required this.nextOffset,
  });

  final List<TwixiveVideo> videos;
  final List<TwixiveUser> users;
  final TwixiveUser? user;
  final String? nextCursor;
  final bool hasMore;
  final int nextOffset;

  factory TwixivePage.fromJson(Map<String, dynamic> json,
      {required int offset, required int limit, bool userVideos = false}) {
    final user =
        json['user'] is Map ? TwixiveUser.fromJson(_map(json['user'])) : null;
    final raw = json[userVideos ? 'videos' : 'items'];
    if (raw is! List) throw const FormatException('视频列表格式异常');
    final videos = <TwixiveVideo>[];
    final users = <TwixiveUser>[];
    for (final value in raw) {
      if (value is! Map) continue;
      final item = _map(value);
      if (!userVideos && item['user'] is Map) {
        final author = TwixiveUser.fromJson(_map(item['user']));
        if (author.identifier.isNotEmpty) users.add(author);
      } else {
        final video = TwixiveVideo.fromJson(
            userVideos ? item : _map(item['video']),
            author: userVideos ? user : null);
        if (video.id.isNotEmpty && video.url.isNotEmpty) videos.add(video);
      }
    }
    final info = _map(json['pageInfo']);
    final cursor = info['nextCursor'];
    final nextCursor = cursor is String && cursor.isNotEmpty ? cursor : null;
    return TwixivePage(
      videos: videos,
      users: users,
      user: user,
      nextCursor: nextCursor,
      hasMore: userVideos
          ? nextCursor != null && info['hasNextPage'] != false
          : raw.length >= limit,
      nextOffset: offset + raw.length,
    );
  }
}
