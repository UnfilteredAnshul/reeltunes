// One place that decides whether a pasted link is worth sending to the engine.
//
// The extractor only knows how to pull audio from short-form video posts, so a
// random URL used to fail 30 seconds into a download. This rejects it up
// front, with one sentence the user can act on.
//
// Accepted:
//   YouTube   youtube.com/shorts/<id>, youtu.be/<id>
//   Instagram instagram.com/reel|reels|p/<id>
//   Facebook  facebook.com/reel|share|videos|watch, fb.watch/<id>
//   TikTok    tiktok.com, vt.tiktok.com, vm.tiktok.com (any short link)
//
// Everything else (YouTube long-form /watch, plain instagram.com profiles,
// share sheets app links, http://) is refused.

const String linkRejectedMessage =
    'Use a YouTube Shorts, Instagram Reel, Facebook or TikTok link.';

/// Null when [raw] is acceptable, otherwise a short reason for the user.
String? linkProblem(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return 'Paste a link first';
  if (text.length > 2048) return 'That link is too long';

  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return "That doesn't look like a link";
  }
  if (uri.scheme.toLowerCase() != 'https') {
    return 'Only https links work';
  }

  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();

  if (host == 'youtu.be' || _isUnder(host, 'youtube.com')) {
    // Shorts only: /watch links are long-form and usually music-licensed.
    if (host == 'youtu.be') return null;
    if (path.startsWith('/shorts/')) return null;
    return 'Only YouTube Shorts links work (not /watch)';
  }

  if (_isUnder(host, 'instagram.com')) {
    if (path.startsWith('/reel/') ||
        path.startsWith('/reels/') ||
        path.startsWith('/p/')) {
      return null;
    }
    return 'Open the Reel and share that link';
  }

  if (host == 'fb.watch' || _isUnder(host, 'fb.watch')) return null;
  if (_isUnder(host, 'facebook.com')) {
    if (path.startsWith('/reel') ||
        path.startsWith('/share/') ||
        path.contains('/videos/') ||
        path.startsWith('/watch')) {
      return null;
    }
    return 'Open the Reel and share that link';
  }

  if (_isUnder(host, 'tiktok.com')) return null;

  return linkRejectedMessage;
}

bool linkAllowed(String raw) => linkProblem(raw) == null;

/// True for the host itself and any sub-domain (`m.`, `vt.`, `www.`).
bool _isUnder(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

/// Stable identity for duplicate detection: scheme-less, query-less,
/// lower-case host+path. `?igsh=…` and `utm_*` noise must not create a
/// second copy of the same reel.
String canonicalLink(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return raw.trim().toLowerCase();
  var host = uri.host.toLowerCase();
  if (host.startsWith('www.')) host = host.substring(4);
  var path = uri.path.toLowerCase();
  if (path.endsWith('/')) path = path.substring(0, path.length - 1);
  return '$host$path';
}
