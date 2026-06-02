import 'dart:convert';

class FqVideoItem {
  FqVideoItem({
    required this.url,
    required this.definition,
    required this.width,
    required this.height,
    required this.bitrate,
    required this.spadeA,
    required this.kid,
    required this.codec,
    this.posterUrl = '',
  });

  final String url;
  final String definition;
  final int width;
  final int height;
  final int bitrate;
  final String spadeA;
  final String kid;
  final String codec;
  String posterUrl;

  factory FqVideoItem.fromJson(Map<String, dynamic> json) {
    // Format A: nested video_meta + encrypt_info (array format)
    final meta = json['video_meta'] as Map<String, dynamic>?;
    final enc = json['encrypt_info'] as Map<String, dynamic>?;

    if (meta != null) {
      return FqVideoItem(
        url: json['main_url']?.toString() ?? '',
        definition: meta['definition']?.toString() ?? '',
        width: meta['vwidth'] as int? ?? 0,
        height: meta['vheight'] as int? ?? 0,
        bitrate: meta['bitrate'] as int? ?? 0,
        spadeA: enc?['spade_a']?.toString() ?? '',
        kid: enc?['kid']?.toString() ?? '',
        codec: meta['codec_type']?.toString() ?? '',
      );
    }

    // Format B: flat fields, main_url is base64 (object format)
    final mainUrlRaw = json['main_url']?.toString() ?? '';
    String url = mainUrlRaw;
    if (mainUrlRaw.isNotEmpty && !mainUrlRaw.startsWith('http')) {
      try {
        url = utf8.decode(base64Decode(mainUrlRaw));
      } catch (_) {}
    }
    return FqVideoItem(
      url: url,
      definition: json['definition']?.toString() ?? '',
      width: json['vwidth'] as int? ?? 0,
      height: json['vheight'] as int? ?? 0,
      bitrate: json['bitrate'] as int? ?? 0,
      spadeA: json['spade_a']?.toString() ?? '',
      kid: json['kid']?.toString() ?? '',
      codec: json['codec_type']?.toString() ?? '',
    );
  }
}
