/// The short-drama host's qv4.q.a.a/c/e rules in Hongguo 73970. These are
/// rendition selection rules, separate from libabrmodule's continuous ABR.
class DramaQualitySelector {
  static const defaultDefinition = '720p';
  // lq4.i.a.b(), reached from qv4.q.a.b -> qv4.p -> host.Z0.
  static const defaultAllowed = ['360p', '480p', '540p', '720p', '1080p'];

  static String? playback({
    required List<String> supported,
    required List<String> allowed,
    String? offline,
    String? manual,
    String? cached,
    String? strategy,
  }) {
    final wanted = offline ?? manual ?? cached ?? strategy ?? defaultDefinition;
    if (supported.isEmpty) return wanted;
    if (supported.contains(wanted) && allowed.contains(wanted)) return wanted;
    // The native host checks 720p in the model before its allowed-list fallback.
    if (supported.contains(defaultDefinition)) return defaultDefinition;
    for (final definition in supported) {
      if (allowed.contains(definition)) return definition;
    }
    return null;
  }

  static String preload({
    required List<String> supported,
    required List<String> allowed,
    String? manual,
    String? cached,
    String? strategy,
  }) {
    if (supported.isEmpty) return defaultDefinition;
    final wanted = manual ?? cached ?? strategy;
    if (wanted != null &&
        supported.contains(wanted) &&
        allowed.contains(wanted)) {
      return wanted;
    }
    if (supported.contains(defaultDefinition)) return defaultDefinition;
    // Preload iterates the host's allowed list; playback iterates the model.
    for (final definition in allowed) {
      if (supported.contains(definition)) return definition;
    }
    return defaultDefinition;
  }

  /// qv4.q.a.e keeps the LAST positive cached rendition other than Standard
  /// (360p), rather than the largest file or the highest numeric resolution.
  static String? cached({
    required List<String> supported,
    required bool Function(String) hasCachedMedia,
  }) {
    String? result;
    for (final definition in supported) {
      if (definition != '360p' && hasCachedMedia(definition)) {
        result = definition;
      }
    }
    return result;
  }
}
