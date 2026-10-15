class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.downloadUrl,
    this.releaseNotes = '',
    this.isRequired = false,
  });

  final String version;
  final String downloadUrl;
  final String releaseNotes;
  final bool isRequired;

  static AppUpdate? fromResponse(Map<String, dynamic> data) {
    if (data['update_available'] == false) return null;
    final version = data['version'];
    final url = data['download_url'];
    final force = data['force_update'];
    final notes = data['release_notes'] ?? '';
    if (data['update_available'] != true ||
        version is! String ||
        version.trim().isEmpty ||
        url is! String ||
        url.trim().isEmpty ||
        force is! bool ||
        notes is! String) {
      throw const FormatException('更新信息无效');
    }
    final uri = Uri.parse(url);
    if (!['http', 'https', 'itms-apps', 'itms-services'].contains(uri.scheme) ||
        ((uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isEmpty) ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('更新下载地址无效');
    }
    return AppUpdate(
      version: version.trim(),
      downloadUrl: url,
      releaseNotes: notes,
      isRequired: force,
    );
  }
}
