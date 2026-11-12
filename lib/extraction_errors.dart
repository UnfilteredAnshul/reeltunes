/// Turns yt-dlp's technical complaints into one short, human sentence.
///
/// The engine reports the extractor's last stderr line, so the raw text can be
/// things like `ERROR: [Instagram] De0CG2ETP90: This content isn't available to
/// everyone`. That is accurate but unreadable, and it leaks platform names, so
/// every failure goes through here before it reaches the log.
///
/// The user-facing toast is deliberately always the same short sentence
/// ("Can't download this one — check the guide"). The guide below explains
/// every kind of failure in plain words, and its search box matches on the
/// technical words as well as the plain ones, so "403" or "private" finds the
/// right entry.
String friendlyExtractionError(Object error) {
  final raw = error.toString().toLowerCase();

  // Login-walled content: private accounts, age gates, "not available to
  // everyone". The app never ships cookies, so this is a hard stop, not a retry.
  if (raw.contains("login") ||
      raw.contains("sign in") ||
      raw.contains("cookies") ||
      raw.contains("isn't available to everyone") ||
      raw.contains("is not available to everyone") ||
      raw.contains("age-restricted") ||
      raw.contains("age restricted") ||
      raw.contains("private")) {
    return "This one is private or needs a login, so it can't be saved. "
        "Try a public reel instead.";
  }

  if (raw.contains("403") || raw.contains("forbidden")) {
    return "The site blocked this download. Try again in a minute, "
        "or use a different link.";
  }

  if (raw.contains("429") || raw.contains("too many requests")) {
    return "Too many requests right now. Wait a minute and try again.";
  }

  if (raw.contains("404") ||
      raw.contains("unavailable") ||
      raw.contains("has been removed") ||
      raw.contains("deleted") ||
      raw.contains("does not exist")) {
    return "That reel is gone, private or blocked in your region.";
  }

  if (raw.contains("unsupported url") ||
      raw.contains("is not a valid url") ||
      raw.contains("no video formats") ||
      raw.contains("unable to find")) {
    return "That link isn't a reel or video ReelTunes can read. "
        "Paste the share link again.";
  }

  if (raw.contains("unable to extract") ||
      raw.contains("failed to parse") ||
      raw.contains("nsig") ||
      raw.contains("player response")) {
    return "The site changed something. Update ReelTunes, then try again.";
  }

  if (raw.contains("timed out") ||
      raw.contains("timeout") ||
      raw.contains("name resolution") ||
      raw.contains("network is unreachable") ||
      raw.contains("connection") ||
      raw.contains("ssl") ||
      raw.contains("certificate")) {
    return "No connection to that site. Check your internet and try again.";
  }

  if (raw.contains("no space") || raw.contains("enospc")) {
    return "Not enough free space on this phone to save that audio.";
  }

  if (raw.contains("permission denied")) {
    return "ReelTunes can't write to the audios folder. "
        "Pick a different folder in Settings.";
  }

  return "Couldn't save that audio. Try a different link.";
}

/// One plain-language explanation shown in the guide.
class DownloadErrorHelp {
  final String title;
  final String body;
  final List<String> keywords;
  const DownloadErrorHelp(this.title, this.body, [this.keywords = const []]);
}

/// Every reason a download can fail, in the order a stuck user should read
/// them. Keep this in sync with [friendlyExtractionError].
const List<DownloadErrorHelp> downloadErrorHelp = [
  DownloadErrorHelp(
    'Private, deleted or needs a login',
    'The reel is private, age-restricted, or the account is not public. '
        'ReelTunes never signs in to Instagram, TikTok or YouTube, so it '
        'cannot open these. Find a public version of the reel and try again.',
    ['private', 'login', 'sign in', 'cookies', 'age', 'deleted', 'gone',
      'removed', 'unavailable', '404'],
  ),
  DownloadErrorHelp(
    'The site blocked the download',
    'Instagram, TikTok and YouTube sometimes refuse a request (error 403). '
        'Wait a minute, then try once more. If it keeps failing, open the reel '
        'in the app and share it again, or use a different link.',
    ['403', 'forbidden', 'blocked', 'not allowed', 'denied'],
  ),
  DownloadErrorHelp(
    'Too many tries at once',
    'The site is rate-limiting this phone (error 429). Wait a few minutes '
        'before trying again. Downloading several reels back to back can '
        'trigger this.',
    ['429', 'too many', 'rate limit', 'rate-limit'],
  ),
  DownloadErrorHelp(
    'The link is not a reel or video',
    'The pasted text is a profile, a photo post, a story or a shortened link '
        'the extractor cannot follow. Open the video, tap Share, and pick '
        'ReelTunes. A link that starts with https:// is required.',
    ['unsupported', 'not a valid url', 'no video formats', 'unable to find',
      'invalid', 'profile', 'photo'],
  ),
  DownloadErrorHelp(
    'The site changed something',
    'The platform updated how it serves videos. Update ReelTunes from Google '
        'Play, then try the same link again. If the update is not out yet, '
        'the download will work again after the next release.',
    ['unable to extract', 'failed to parse', 'nsig', 'player response',
      'signature', 'update'],
  ),
  DownloadErrorHelp(
    'No internet connection',
    'The phone could not reach the site: no data, Wi-Fi dropped, a captive '
        'portal, or a certificate problem. Check the connection, turn off any '
        'VPN or private DNS that may block the site, and try again.',
    ['timed out', 'timeout', 'network', 'connection', 'ssl', 'certificate',
      'dns', 'unreachable', 'offline'],
  ),
  DownloadErrorHelp(
    'Not enough free space',
    'The phone ran out of storage while writing the audio. Free up space '
        '(photos, videos, other apps), then try the same link again. Nothing '
        'in your library is deleted.',
    ['no space', 'enospc', 'storage', 'disk full'],
  ),
  DownloadErrorHelp(
    'ReelTunes cannot write to the folder',
    'Android dropped permission for the audios folder, usually after a '
        'reinstall or a system clean-up. Open Settings, tap Audios folder, and '
        'pick the same folder again. Your audios are still on the phone.',
    ['permission denied', 'permission', 'folder', 'write', 'eacces',
      'reconnect'],
  ),
  DownloadErrorHelp(
    'The download finished but was not saved',
    'ReelTunes checks the file after every attempt and retries a few times '
        'before giving up. If the audio shows up in your library anyway, it is '
        'safe to ignore the message. If it does not, try the link once more.',
    ['couldn\'t save', 'no file', 'verify', 'retry', 'missing'],
  ),
  DownloadErrorHelp(
    'Something else',
    'Try the link once more. If it still fails, use the folder button to '
        'import the audio or video you already have, or send the link through '
        'Settings → Send feedback so it can be checked.',
    ['other', 'unknown', 'failed', 'error'],
  ),
];

/// The guide entry that best matches an extraction error, or null.
DownloadErrorHelp? downloadErrorFor(Object error) {
  final raw = error.toString().toLowerCase();
  for (final entry in downloadErrorHelp) {
    for (final word in entry.keywords) {
      if (raw.contains(word)) return entry;
    }
  }
  return null;
}
