// Playback engine: just_audio (+ just_audio_background) + ReelTune's
// advanced looping. One process-wide player; the app always plays the same
// track. Background playback / lock-screen & media widget come from
// just_audio_background (MediaSession with MediaItem tags per track).
//
// IMPORTANT: just_audio_background must finish init() BEFORE any AudioPlayer
// exists — so the AudioPlayer is created inside _boot() and every public
// player operation awaits _whenReady() first.

import 'dart:async';
import 'dart:math';

import 'package:audio_session/audio_session.dart' as asess;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'entitlements.dart';
import 'error_report.dart';
import 'models.dart';

class RtPlayer extends ChangeNotifier {
  RtPlayer._() {
    _boot();
  }
  static final RtPlayer I = RtPlayer._();

  // Created only after JustAudioBackground.init completes.
  AudioPlayer? _ap;
  final Completer<void> _bootCompleter = Completer<void>();
  bool _booted = false;
  Future<void>? _bgInit;

  Track? current;
  List<Track> queue = [];
  int queueIndex = -1;

  /// Playlist context label, e.g. "All" or a folder name — shown as
  /// "playing from …" in the player. Set at play() time from the active
  /// library filter (or an explicit folder when shuffle-played directly).
  String playingFrom = 'All';

  /// Advanced looping: smart or custom-range. Shuffle is always on by design.
  RtLoop loop = RtLoop.smart;
  bool shuffleOn = true;

  bool _wasPlayingBeforeInterruption = false;
  int _targetLoops = 1;
  /// Completed passes of the CURRENT track. "3 loops" = the track plays 3
  /// full times, so with a 3-5 range you get exactly 3, 4 or 5 plays.
  int _passes = 0;
  /// True once the loop decision for the pass in flight has been made, so the
  /// 200 ms position ticks can't count the same ending twice.
  bool _targetLatched = false;
  Duration _lastPos = Duration.zero;
  /// Index changes inside this window are user/deck-driven, not "a track
  /// finished its loops" — Smart learning must not treat a skip as a vote.
  DateTime _manualAdvanceUntil = DateTime.fromMillisecondsSinceEpoch(0);
  /// Consecutive failed loads. Broken files are skipped, but if EVERY file
  /// fails we must stop instead of looping forever (that loop was the
  /// "crashes 2 s after tapping play").
  int _loadFailures = 0;
  /// True while `removeIfCurrent` is mutating both the engine playlist and our
  /// `queue`. Index/completion events fired by the platform mid-surgery would
  /// otherwise be interpreted as "a track finished" and move the UI to a row
  /// that does not match what is actually playing.
  bool _queueSurgery = false;
  bool get queuePlayable => queue.isNotEmpty && queueIndex >= 0;

  bool get playing {
    final ap = _ap;
    return _booted && ap != null && ap.playing && current != null;
  }

  /// Media-session service setup + player creation. Started right after
  /// runApp() — never blocks the app launch.
  Future<void> ensureBackgroundService() async {
    if (_bgInit != null) return _bgInit;
    // Retry up to 3 times — ColorOS can be flaky initializing the background
    // audio service on first attempt. Each attempt has a 10 s timeout so a
    // hung init never blocks the app launch forever.
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        _bgInit = JustAudioBackground.init(
          androidNotificationChannelId: 'com.buildwithanshul.reeltunes.playback',
          androidNotificationChannelName: 'ReelTunes playback',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
        );
        await _bgInit!.timeout(const Duration(seconds: 5));
        debugPrint('JustAudioBackground.init succeeded (attempt $attempt)');
        return _bgInit!;
      } catch (e, s) {
        debugPrint('JustAudioBackground.init attempt $attempt failed: $e');
        if (attempt == 3) {
          reportError('audio service init failed after 3 attempts', e, s);
          _bgInit = null; // allow retry next time
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<void> _boot() async {
    try {
      await ensureBackgroundService();
    } catch (e, s) {
      // Media session unavailable — degrade to plain in-app playback.
      reportError('media session init failed', e, s);
    }
    final ap = AudioPlayer(handleInterruptions: false);
    // Engine state is the single source of truth for the UI: play/pause
    // glyphs flip the instant the platform changes, no matter who initiated
    // it (mini bar, player sheet, notification, headset, interruption).
    ap.playerStateStream.listen((_) => _silentFire());
    ap.playingStream.listen((_) => _silentFire());
    // Per-track loop steering (see _onPosition / _onIndexChange).
    ap.positionStream.listen(_onPosition);
    // Whole-queue end (only reachable on the last pass of the last item).
    ap.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) _onPlaylistEnd();
    });
    // Manual interruption handling via audio_session (just_audio 0.10.x has
    // no public interruption stream) so "keep playing during calls" works.
    asess.AudioSession.instance.then((session) {
      session.interruptionEventStream.listen(_onInterruption);
      session.becomingNoisyEventStream.listen((_) => ap.pause());
    });
    // Notification / media-widget / auto-advance driven index changes stay in
    // sync here.
    ap.currentIndexStream.listen(_onIndexChange);
    _ap = ap;
    _booted = true;
    _bootCompleter.complete();
    _silentFire();
  }

  Future<void> _whenReady() async {
    if (!_booted) await _bootCompleter.future;
  }

  // ---- streams for UI ----
  Stream<Duration> get positionStream => _booted
      ? _ap!.positionStream
      : const Stream<Duration>.empty();
  Stream<Duration?> get durationStream => _booted
      ? _ap!.durationStream
      : const Stream<Duration?>.empty();
  Duration? get duration => _booted ? _ap!.duration : null;
  /// Authoritative play/pause state straight from the engine — used by UI
  /// that must reflect the button state instantly (mini bar pause/play).
  Stream<bool> get playingStream =>
      _booted && _ap != null ? _ap!.playingStream : const Stream<bool>.empty();

  /// Fisher–Yates with a fresh RNG per call, then move the tapped track to
  /// the front. A new Random() is seeded with process entropy, so restarting
  /// the app always yields a different order — no cursed 2→5→1→3 replays.
  List<Track> _shuffled(List<Track> src, Track head) {
    final list = List.of(src);
    final rnd = Random(DateTime.now().microsecondsSinceEpoch ^
        DartHashSeedRandomSalt);
    for (var i = list.length - 1; i > 0; i--) {
      final j = rnd.nextInt(i + 1);
      final tmp = list[i];
      list[i] = list[j];
      list[j] = tmp;
    }
    list.removeWhere((t) => t.id == head.id);
    return [head, ...list];
  }

  Future<void> play(Track t,
      {List<Track>? context, String? playingFrom}) async {
    var ctx = context ?? queue;
    this.playingFrom = playingFrom ??
        (AppStore.I.selectedFolderId == null
            ? 'All'
            : (AppStore.I.folderById(AppStore.I.selectedFolderId!)?.name ??
                'All'));
    if (shuffleOn) {
      queue = _shuffled(ctx, t);
    } else if (ctx.isNotEmpty) {
      queue = ctx;
    } else {
      queue = [t];
    }
    queueIndex = 0;
    current = queue.first;
    return _startCurrent();
  }

  /// Local files play from their path; SAF/content URIs (files imported
  /// without an app-side copy) play straight from the URI.
  AudioSource _sourceFor(Track q) {
    final tag = MediaItem(
      id: q.id,
      title: q.title,
      artist: playingFrom.isNotEmpty && playingFrom != 'All'
          ? '$playingFrom · ${q.source}'
          : q.source,
      album: playingFrom.isNotEmpty && playingFrom != 'All' ? playingFrom : null,
      duration:
          q.durationMs > 0 ? Duration(milliseconds: q.durationMs) : null,
    );
    final path = q.path;
    if (path.contains('://')) {
      return AudioSource.uri(Uri.parse(path), tag: tag);
    }
    return AudioSource.file(path, tag: tag);
  }

  /// Loads the (shuffled) queue as one audio source so the media session has
  /// next/previous context, then starts at queueIndex.
  Future<void> _startCurrent() async {
    try {
      await _whenReady();
    } catch (e) {
      debugPrint('player boot failed: $e');
      reportError('player engine failed to start', e, null);
      return;
    }
    final t = queue[queueIndex];
    current = t;
    AppStore.I.setLastPlayedId(t.id);
    _silentFire();
    try {
      final sources = <AudioSource>[for (final q in queue) _sourceFor(q)];
      // One source per queue row — never a nested ConcatenatingAudioSource.
      // With nesting, the player's own playlist has a single child while
      // `queue` has N rows, so `removeAudioSourceAt(i)` deleted the whole
      // nested playlist (or threw) and the UI/engine drifted apart.
      await _ap!.setAudioSources(
        sources,
        initialIndex: queueIndex.clamp(0, sources.length - 1),
      );
      _rememberDuration(t);
      // Draw this track's loop count AFTER loading, so the engine duration
      // (and therefore Smart's short-clip boost) is already known.
      _newTrackLoops();
      // JustAudioBackground-style play(): the future completes when playback
      // STOPS, so awaiting it here would freeze every subsequent state update.
      unawaited(_ap!.play());
      _loadFailures = 0;
    } catch (e, s) {
      reportError('play failed for "${t.title}"', e, s);
      _loadFailures++;
      // Skip a broken file instead of hanging the queue — but once every
      // file in the queue has failed, stop. Failure→skip→failure looping
      // forever froze the app in ~2 s.
      if (_loadFailures <= queue.length) skipNext();
    }
    _silentFire();
  }

  /// Stores a track's duration the first time the engine knows it. Without
  /// this, the first play of a fresh import reported 0:00 for the whole clip
  /// (nothing had been persisted yet, and the old read-once lookup ran before
  /// the engine had a duration to report).
  void _rememberDuration(Track t) {
    final known = _ap!.duration;
    if (known != null && known.inMilliseconds > 0) {
      AppStore.I.updateTrackDuration(t.id, known.inMilliseconds);
      return;
    }
    late final StreamSubscription<Duration?> sub;
    sub = _ap!.durationStream.listen((d) {
      if (d == null || d.inMilliseconds <= 0) return;
      sub.cancel();
      // Only trust it while still sitting on the track we loaded for.
      if (current?.id == t.id) {
        AppStore.I.updateTrackDuration(t.id, d.inMilliseconds);
      }
    });
  }

  /// Length hint for loop decisions: the persisted track duration first
  /// (available instantly), then whatever the engine currently reports.
  int _durationSecondsHint() {
    final known = current?.durationMs ?? 0;
    if (known > 0) return (known / 1000).round();
    return _ap?.duration?.inSeconds ?? 0;
  }

  /// How many times the current track should play.
  /// - Custom range: a fresh random draw from the user's min..max (3-3 means
  ///   exactly 3 plays).
  /// - Smart: samples the user's own recent custom-range history so it learns
  ///   that this person repeats reels 6-8 times, not 3-5. With no history yet
  ///   it uses the same range. Short reels (<30 s) get one extra pass.
  int _loopsTarget() {
    final store = AppStore.I;
    // Play once, then move to the next audio. This is also what deselecting
    // Smart / Custom range means.
    if (loop == RtLoop.off) return 1;
    // Custom range is Pro-only. A lapsed subscription falls back to Smart
    // instead of keeping a range the user can no longer edit.
    if (loop == RtLoop.customRange && Entitlements.I.canUseCustomRange) {
      return randomLoopCount(store.rangeMin, store.rangeMax);
    }
    final learned = store.learnedLoopCount();
    // Free Smart is 3-6 (docs/free-vs-pro.md); Pro learns from history.
    var target = learned ??
        randomLoopCount(Entitlements.smartMin, Entitlements.smartMax);
    final secs = _durationSecondsHint();
    if (secs > 0 && secs < 30) target += 1;
    return target.clamp(1, 99);
  }

  Future<void> toggle() async {
    if (current == null) return;
    await _whenReady();
    final ap = _ap!;
    if (ap.playing) {
      await ap.pause();
    } else {
      // play() completes only when playback stops — never await it.
      unawaited(ap.play());
    }
    _silentFire();
  }

  Future<void> seek(double fraction) async {
    await _whenReady();
    final d = _ap!.duration;
    if (d != null) await _ap!.seek(d * fraction);
  }

  /// User skip: losing the remaining loops of the current track is by
  /// design — the next track draws its own random loop count. Advances
  /// INSIDE the already-loaded queue (seek by index) instead of reloading
  /// the whole audio source, so switches are gapless and the media
  /// session/notification state transitions stay consistent.
  Future<void> skipNext() async {
    if (queue.isEmpty) return;
    _markManualAdvance();
    final next = (queueIndex + 1) % queue.length;
    if (!_booted || _ap == null) {
      queueIndex = next;
      return _startCurrent();
    }
    try {
      await _ap!.seek(Duration.zero, index: next);
    } catch (e, s) {
      reportError('skip failed', e, s);
      // Fallback to the reload path so skipping never dead-ends.
      queueIndex = next;
      await _startCurrent();
    }
  }

  Future<void> skipPrev() async {
    await _whenReady();
    if (_ap!.position > const Duration(seconds: 3)) {
      await _ap!.seek(Duration.zero);
      return;
    }
    // Spotify-style: restart when <3 s in; otherwise jump to the previous
    // track (wrap-around).
    final prev = (queueIndex - 1 + queue.length) % queue.length;
    if (prev == queueIndex || queue.isEmpty) {
      await _ap!.seek(Duration.zero);
      return;
    }
    _markManualAdvance();
    try {
      await _ap!.seek(Duration.zero, index: prev);
    } catch (e, s) {
      reportError('previous failed', e, s);
      await _ap!.seek(Duration.zero);
    }
  }

  void setLoop(RtLoop m) {
    loop = m;
    // Re-draw the count and re-arm per-item looping for the track in flight.
    _newTrackLoops();
    _silentFire();
  }

  /// Shuffle is on by default (ReelTunes' identity). Toggling it only
  /// changes the order used by the NEXT play()/queue build — the current
  /// queue keeps playing untouched.
  void toggleShuffle() {
    shuffleOn = !shuffleOn;
    _silentFire();
  }

  // ---- per-track looping -------------------------------------------------
  //
  // Why not ProcessingState.completed? Inside a ConcatenatingAudioSource the
  // platform auto-advances, so "completed" only ever fires at the END of the
  // whole queue — the old counter never ran, and every track played once.
  //
  // Now: every track starts in LoopMode.one (ExoPlayer repeat-one = the
  // current item repeats exactly, gaplessly, even in the background). The
  // position watcher counts passes and, on the last one, switches loop mode
  // off so the queue moves on at the natural boundary. Infinite mode simply
  // never switches it off.
  void _newTrackLoops() {
    _passes = 0;
    _lastPos = Duration.zero;
    _targetLatched = _durationSecondsHint() > 0;
    _targetLoops = _loopsTarget();
    _armLoopMode();
  }

  void _armLoopMode() {
    final ap = _ap;
    if (ap == null) return;
    // "Play once" arms the engine off from the start: no position event has to
    // land in the last 900 ms for a very short clip to advance, and it keeps
    // working when the app is backgrounded and ticks are sparse.
    unawaited(
        ap.setLoopMode(loop == RtLoop.off ? LoopMode.off : LoopMode.one));
  }

  void _markManualAdvance() {
    _manualAdvanceUntil = DateTime.now().add(const Duration(seconds: 1));
  }

  void _onPosition(Duration pos) {
    final last = _lastPos;
    _lastPos = pos;

    // Detect a wrap: position jumped backward = LoopMode.one repeated the
    // track. This marks the START of a new pass. Count passes and switch to
    // LoopMode.off at the start of the final pass so the engine has plenty of
    // time to prepare the next track — no stutter at the boundary.
    if (pos < last - const Duration(milliseconds: 500)) {
      _passes++;
      if (loop != RtLoop.off && loop != RtLoop.infinite &&
          _passes >= _targetLoops) {
        final ap = _ap;
        if (ap != null) unawaited(ap.setLoopMode(LoopMode.off));
      }
      return;
    }

    // Play-once never loops: the engine was armed off when the track loaded.
    if (loop == RtLoop.off) return;

    final d = _ap?.duration;
    if (d == null || d.inMilliseconds <= 0) return;

    // First real duration of this track: latch the target now so Smart's
    // short-clip boost is based on the actual length.
    if (!_targetLatched) {
      _targetLoops = _loopsTarget();
      _targetLatched = true;
    }

    if (loop == RtLoop.infinite) return; // never advances by itself
  }

  void _onIndexChange(int? i) {
    // Mid-surgery the platform index is briefly out of step with `queue`;
    // `removeIfCurrent` owns the state and will settle it.
    if (_queueSurgery) return;
    if (i == null || !queuePlayable || i == queueIndex) return;
    final natural = DateTime.now().isAfter(_manualAdvanceUntil);
    // Smart learning: a custom-range track that played out its whole count
    // is a real signal of how deep this user likes their loops.
    if (natural &&
        loop == RtLoop.customRange &&
        _targetLoops > 0 &&
        _passes >= _targetLoops) {
      AppStore.I.recordLoopCount(_targetLoops);
    }
    queueIndex = i;
    current = i < queue.length ? queue[i] : null;
    final loaded = current;
    if (loaded != null) AppStore.I.setLastPlayedId(loaded.id);
    _newTrackLoops();
    _silentFire();
  }

  /// Queue exhausted (last pass of the last item). Wrap to the top instead of
  /// stopping dead — playback here is an endless reel loop.
  Future<void> _onPlaylistEnd() async {
    // A removal can push the engine into "completed" while `queue` is being
    // rebuilt — that is not the end of the queue, so don't seek to the top.
    if (_queueSurgery) return;
    if (!queuePlayable) return;
    // The last queue item ends here instead of an index change — record its
    // custom-range completion before wrapping (same Smart-learning signal).
    if (loop == RtLoop.customRange &&
        _targetLoops > 0 &&
        _passes >= _targetLoops) {
      AppStore.I.recordLoopCount(_targetLoops);
    }
    _markManualAdvance();
    try {
      await _ap!.seek(Duration.zero, index: 0);
      _newTrackLoops();
      unawaited(_ap!.play());
    } catch (e, s) {
      reportError('wrap-around failed', e, s);
    }
    _silentFire();
  }

  /// Audio-focus interruptions (calls, alarms, other apps). Default pauses;
  /// when the user has enabled "keep playing during calls" we try to ride
  /// through them instead.
  void _onInterruption(asess.AudioInterruptionEvent e) {
    if (e.begin) {
      _wasPlayingBeforeInterruption = playing;
      if (!AppStore.I.playDuringCalls) {
        _ap?.pause();
      } else {
        // Keep going — re-assert play with fresh focus.
        _ap?.play();
      }
    } else {
      if (_wasPlayingBeforeInterruption && !AppStore.I.playDuringCalls) {
        _ap?.play();
      }
    }
  }

  /// A track was removed from the library. Keep playing: the queue drops the
  /// item and, if it was the one playing, the next one starts instead of
  /// silence. (Previously this stopped the player dead.)
  ///
  /// Order matters: our `queue`/`queueIndex`/`current` are updated FIRST, then
  /// the engine playlist is edited, then the engine is asked to land on the new
  /// index. Doing it the other way round let the platform's index events race
  /// ahead of the list and made the UI show "pqr" while "abc" was audible.
  Future<void> removeIfCurrent(String id) async {
    final idx = queue.indexWhere((t) => t.id == id);
    if (idx < 0) {
      if (current?.id == id) {
        current = null;
        if (_booted) await _ap!.stop();
        _silentFire();
      }
      return;
    }
    final wasCurrent = queueIndex == idx;
    final wasPlaying = playing;
    _markManualAdvance();
    _queueSurgery = true;
    try {
      queue.removeAt(idx);
      if (queue.isEmpty) {
        current = null;
        queueIndex = -1;
      } else {
        // Removing an earlier row shifts the live row one place up; removing
        // the live row itself leaves its successor at the same position (the
        // clamp keeps us on the previous row when the last one is removed).
        if (idx < queueIndex) queueIndex--;
        queueIndex = queueIndex.clamp(0, queue.length - 1);
        current = queue[queueIndex];
        AppStore.I.setLastPlayedId(current!.id);
      }
      _silentFire();

      if (_booted && _ap != null) {
        try {
          await _ap!.removeAudioSourceAt(idx);
        } catch (e, s) {
          // The engine playlist can already differ (older builds nested it).
          // Rebuilding from `queue` is the only safe recovery.
          reportError('queue remove failed', e, s);
          await _rebuildQueueAt(queueIndex);
          if (wasPlaying) unawaited(_ap!.play());
          return;
        }
      }

      if (queue.isEmpty) {
        if (_booted) await _ap!.stop();
        return;
      }

      if (wasCurrent && _booted && _ap != null) {
        try {
          // The removed row may have been the last one, leaving the engine
          // parked at the end. Land on the row that took its place, at 0:00.
          await _ap!.seek(Duration.zero, index: queueIndex);
        } catch (e, s) {
          reportError('advance after remove failed', e, s);
        }
        _newTrackLoops();
        if (wasPlaying) unawaited(_ap!.play());
      }
    } finally {
      _queueSurgery = false;
      _silentFire();
    }
  }

  /// Reloads the engine playlist from `queue` and seeks to [index] (paused).
  /// Only used as a recovery path when the engine and our list disagree.
  Future<void> _rebuildQueueAt(int index) async {
    final ap = _ap;
    if (ap == null || queue.isEmpty) return;
    final target = index.clamp(0, queue.length - 1);
    try {
      await ap.setAudioSources(
        [for (final q in queue) _sourceFor(q)],
        initialIndex: target,
      );
      queueIndex = target;
      current = queue[target];
      _newTrackLoops();
    } catch (e, s) {
      reportError('queue rebuild failed', e, s);
    }
  }

  void _silentFire() => notifyListeners();
}

// A per-process salt so seed differs even if the epoch micros ever collide
const int DartHashSeedRandomSalt = 0x5f4d9e17;
