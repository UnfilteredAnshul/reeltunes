/// Turns yt-dlp's technical complaints into one short, human sentence.
///
/// The engine reports the extractor's last stderr line, so the raw text can be
/// things like `ERROR: [Instagram] De0CG2ETP90: This content isn't available to
/// everyone`. That is accurate but unreadable, and it leaks platform names, so
/// every failure goes through here before it reaches a snackbar.
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
