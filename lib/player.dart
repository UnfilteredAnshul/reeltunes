// Playback engine: just_audio + ReelTune's advanced looping. One process-wide
// player; the app always plays the same track.
//
// The lock-screen / notification-shade player is NOT a plugin: PlaybackService
// (Kotlin) owns a MediaSessionCompat + MediaStyle notification and Dart pushes
// the state into it through PlaybackNotification. That is deliberate —
// audio_service never reached startForeground on this device, so the
// notification silently never appeared.

import 'dart:async';
import 'dart:math';

import 'package:audio_session/audio_session.dart' as asess;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'cover_art.dart';
import 'entitlements.dart';
import 'error_report.dart';
import 'folder_access.dart';
import 'library_sync.dart';
import 'media_notification.dart';
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
  /// Set while "Keep playing during calls" is holding playback through an
  /// interruption. A play() issued while the call UI owns audio focus is
  /// rejected, so we retry instead of giving up after one attempt.
  Timer? _callHold;
  /// Engine volume, 0..1. Session-only: a fresh launch starts at full volume so
  /// a muted phone is never mistaken for broken audio.
  double volume = 1.0;
  double _volumeBeforeMute = 1.0;
  int _targetLoops = 1;
  /// Passes of the CURRENT track that have reached their tail. "3 loops" = the
  /// track plays 3 full times, so with a 3-5 range you get exactly 3, 4 or 5
  /// plays. Counted from the last-stretch tick, which fires even when the
  /// app is backgrounded and the position stream is sparse.
  int _played = 0;
  /// True once the current pass reached its last stretch, so one pass can
  /// never be counted twice by consecutive ticks.
  bool _endSeen = false;
  /// True once the engine has been told that the pass in flight is the last
  /// one. LoopMode is flipped off at the START of that pass, never near its
  /// end: a platform call that lands late is exactly what made a finished clip
  /// replay for a moment before the next one started.
  bool _finalPassArmed = false;
  /// The loop target is latched the first time a real duration is known, so
  /// Smart's short-clip boost sees the actual length (not 0 during load).
  bool _targetLatched = false;
  Duration _lastPos = Duration.zero;
  /// Queue row the [_lastPos] tick belongs to. When this differs from
  /// [queueIndex] the position went to zero because a NEW track started, not
  /// because the current one wrapped.
  int _tickIndex = -1;
  /// Position ticks inside this window are seek artefacts, not a pass wrap.
  DateTime _ignoreWrapUntil = DateTime.fromMillisecondsSinceEpoch(0);
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
  /// Guards the cycle reload: `completed` can land while the new source list
  /// is still loading, and wrapping twice would reshuffle and reload again.
  bool _wrapping = false;
  bool get queuePlayable => queue.isNotEmpty && queueIndex >= 0;

  bool get playing {
    final ap = _ap;
    return _booted && ap != null && ap.playing && current != null;
  }

  /// Binds the native media session. Started right after runApp(), never
  /// blocks the app launch, and playback does not depend on the result: with no
  /// session the app still plays, it just has no shade/lock-screen controls.
  Future<void> ensureBackgroundService() => _bgInit ??= _initMediaSession();

  Future<void> _initMediaSession() async {
    PlaybackNotification.onPlay = resume;
    PlaybackNotification.onPause = pause;
    PlaybackNotification.onToggle = toggle;
    PlaybackNotification.onNext = skipNext;
    PlaybackNotification.onPrevious = skipPrev;
    PlaybackNotification.onStop = stopFromSystem;
    PlaybackNotification.onSeek = seekToMillis;
    final ok = await PlaybackNotification.init();
    mediaSessionReady = ok;
    mediaSessionFailed = !ok;
    if (!ok) {
      reportError(
        'media session unavailable',
        'PlaybackService did not answer',
        null,
        userMessage:
            'Playback controls are unavailable. Allow notifications for '
            'ReelTunes in Settings.',
      );
    }
    _pushMediaState();
  }

  /// True once the media session (notification + lock screen controls) is up.
  bool mediaSessionReady = false;

  /// True when the service refused to start on this phone. The Settings
  /// notification row uses it to explain what to allow instead of silently
  /// promising controls that never appear.
  bool mediaSessionFailed = false;

  /// Pushes one snapshot to the notification/lock screen. Called on every
  /// transition (play, pause, track change, seek) — never on position ticks.
  void _pushMediaState() {
    final t = current;
    final ap = _ap;
    if (t == null || ap == null) {
      unawaited(PlaybackNotification.clear());
      return;
    }
    final total = ap.duration?.inMilliseconds ??
        (t.durationMs > 0 ? t.durationMs : 0);
    unawaited(PlaybackNotification.update(
      id: t.id,
      title: t.title,
      artist: playingFrom.isNotEmpty && playingFrom != 'All'
          ? '$playingFrom · ${t.source}'
          : t.source,
      album: playingFrom.isNotEmpty && playingFrom != 'All'
          ? playingFrom
          : 'ReelTunes',
      cover: coverIndexFor(t.id),
      playing: ap.playing,
      positionMs: ap.position.inMilliseconds,
      durationMs: total,
      hasNext: queue.length > 1,
      hasPrevious: queue.length > 1,
    ));
  }

  Future<void> _boot() async {
    // The session is independent of the engine now, so this cannot hold
    // playback hostage (the old audio_service init could hang on ColorOS).
    unawaited(ensureBackgroundService());
    // Android only routes audio into the media session (and shows the
    // lock-screen player) when the app's audio session is configured for
    // music.
    try {
      final session = await asess.AudioSession.instance;
      await session.configure(const asess.AudioSessionConfiguration.music());
    } catch (e) {
      debugPrint('audio session configure failed: $e');
    }
    final ap = AudioPlayer(handleInterruptions: false);
    unawaited(ap.setVolume(volume));
    // Engine state is the single source of truth for the UI: play/pause
    // glyphs flip the instant the platform changes, no matter who initiated
    // it (mini bar, player sheet, notification, headset, interruption).
    ap.playerStateStream.listen((_) => _silentFire());
    ap.playingStream.listen((_) {
      _silentFire();
      // The notification's play/pause action must match reality even when the
      // change came from an interruption or the end of the queue.
      _pushMediaState();
    });
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
      // Headphones unplugged: pause and forget the pre-interruption state, so
      // nothing resumes when they are plugged back in.
      session.becomingNoisyEventStream.listen((_) {
        _stopHold();
        _wasPlayingBeforeInterruption = false;
        ap.pause();
      });
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

  /// Fisher–Yates with a fresh secure RNG per call. The old time-seeded
  /// `Random` could repeat a whole permutation when two deals landed in the
  /// same tick (and left the order suspiciously close between cycles); a
  /// CSPRNG removes that class of "same shuffle twice" bugs entirely.
  Random _rng() {
    try {
      return Random.secure();
    } catch (_) {
      return Random(DateTime.now().microsecondsSinceEpoch);
    }
  }

  List<Track> _fisherYates(List<Track> src) {
    final list = List.of(src);
    final rnd = _rng();
    for (var i = list.length - 1; i > 0; i--) {
      final j = rnd.nextInt(i + 1);
      final tmp = list[i];
      list[i] = list[j];
      list[j] = tmp;
    }
    return list;
  }

  bool _sameOrder(List<Track> a, List<Track> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  /// Shuffle order for a new cycle: [head] plays first, then everything else
  /// exactly once. That is the whole no-repeats guarantee — one cycle is a
  /// permutation of the context, so no audio can come back before every other
  /// one has played.
  List<Track> _shuffled(List<Track> src, Track head) {
    final list = _fisherYates(src)..removeWhere((t) => t.id == head.id);
    return [head, ...list];
  }

  /// Permutation for the NEXT cycle, reshuffled from scratch. The audio that
  /// just finished is pushed off the head, so a cycle never restarts on the
  /// same song it ended with.
  ///
  /// Two hard guarantees on top of the shuffle: the new cycle never repeats the
  /// order that just finished, and never opens on the same audio as it. Both
  /// re-deal if the draw lands there, so "the second shuffle looked identical"
  /// cannot come from the deal itself.
  List<Track> _nextCycle(List<Track> src, String? lastId) {
    if (src.length < 2) return List.of(src);
    final oldHead = src.first.id;
    var list = _fisherYates(src);
    var guard = 0;
    while (guard++ < 8 && (_sameOrder(list, src) || list.first.id == oldHead)) {
      list = _fisherYates(src);
    }
    if (list.first.id == lastId) {
      final j = 1 + _rng().nextInt(list.length - 1);
      final tmp = list[0];
      list[0] = list[j];
      list[j] = tmp;
    }
    return list;
  }

  /// True when [ctx] holds the same audios as the queue already loaded, so the
  /// cycle in flight can be kept instead of reshuffled. Order is irrelevant:
  /// the queue is a permutation of the context, membership is what counts.
  bool _sameCycle(List<Track> ctx) {
    if (queue.isEmpty || ctx.length != queue.length) return false;
    final ids = {for (final t in queue) t.id};
    for (final t in ctx) {
      if (!ids.contains(t.id)) return false;
    }
    return true;
  }

  Future<void> play(Track t,
      {List<Track>? context,
      String? playingFrom,
      bool freshCycle = false}) async {
    final ctx = context ?? queue;
    this.playingFrom = playingFrom ??
        (AppStore.I.selectedFolderId == null
            ? 'All'
            : (AppStore.I.folderById(AppStore.I.selectedFolderId!)?.name ??
                'All'));
    _markManualAdvance();
    final inQueue = queue.indexWhere((x) => x.id == t.id);

    // Already inside the cycle in flight: jump to it instead of rebuilding the
    // order. Rebuilding was the real "shuffle repeats songs" bug — every tap
    // threw the half-played cycle away and dealt a fresh one.
    if (!freshCycle &&
        inQueue >= 0 &&
        _booted &&
        _ap != null &&
        _sameCycle(ctx)) {
      if (inQueue == queueIndex) {
        queueIndex = inQueue;
        current = queue[inQueue];
        await _whenReady();
        try {
          await _ap!.seek(Duration.zero);
          _newTrackLoops();
          unawaited(_ap!.play());
        } catch (e, s) {
          reportError('replay failed', e, s);
        }
      } else {
        await _whenReady();
        try {
          await _ap!.seek(Duration.zero, index: inQueue);
          // A seek does not resume: tapping a row while paused must play it.
          unawaited(_ap!.play());
        } catch (e, s) {
          reportError('jump failed', e, s);
          queueIndex = inQueue;
          await _startCurrent();
        }
      }
      _pushMediaState();
      _silentFire();
      return;
    }

    if (ctx.isEmpty) {
      queue = [t];
    } else if (shuffleOn && ctx.length > 1) {
      queue = _shuffled(ctx, t);
    } else {
      queue = List.of(ctx);
    }
    queueIndex = queue.indexWhere((x) => x.id == t.id);
    if (queueIndex < 0) {
      queue = [t, ...queue];
      queueIndex = 0;
    }
    current = queue[queueIndex];
    return _startCurrent();
  }

  /// Local files play from their path; SAF/content URIs (files imported
  /// without an app-side copy) play straight from the URI. The notification
  /// metadata is pushed separately by [_pushMediaState], so no tag is needed.
  AudioSource _sourceFor(Track q) {
    final path = q.path;
    if (path.contains('://')) return AudioSource.uri(Uri.parse(path));
    return AudioSource.file(path);
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
      // just_audio's play() completes when playback STOPS, so awaiting it here
      // would freeze every subsequent state update.
      unawaited(_ap!.play());
      _loadFailures = 0;
      _pushMediaState();
    } catch (e, s) {
      // A lapsed SAF grant looks exactly like a broken file: the audios are
      // on disk, but every content:// path fails to open ("Source error").
      // Skipping would cascade this error through the whole queue, so check
      // the folder first and ask for a re-link instead.
      if (await _folderAccessLost()) {
        reportError(
            'audios folder lost access',
            e,
            s,
            userMessage: 'Your audios folder needs reconnecting. '
                'Tap Settings → Audios folder.');
        _silentFire();
        return;
      }
      reportError('play failed for "${t.title}"', e, s);
      _loadFailures++;
      // Skip a broken file instead of hanging the queue — but once every
      // file in the queue has failed, stop. Failure→skip→failure looping
      // forever froze the app in ~2 s.
      if (_loadFailures <= queue.length) skipNext();
    }
    _silentFire();
  }

  /// True when the audios folder itself stopped answering. A lapsed SAF grant
  /// (reinstall, system permission reset, OEM clean-up) makes every
  /// content:// row fail to open while the files stay on disk — the player
  /// sees "Source error" and the user sees files that "can't play".
  Future<bool> _folderAccessLost() async {
    if (!LibrarySync.folder.linked) return false;
    return !await FolderAccess.probe();
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
      _stopHold();
      _wasPlayingBeforeInterruption = false;
      await ap.pause();
    } else {
      // play() completes only when playback stops — never await it.
      unawaited(ap.play());
    }
    _pushMediaState();
    _silentFire();
  }

  /// Explicit resume, used by the notification's play action (toggle would flip
  /// to pause if the shade and the engine ever disagreed).
  Future<void> resume() async {
    if (current == null) return;
    await _whenReady();
    unawaited(_ap!.play());
    _pushMediaState();
    _silentFire();
  }

  Future<void> pause() async {
    if (current == null) return;
    await _whenReady();
    _stopHold();
    _wasPlayingBeforeInterruption = false;
    await _ap!.pause();
    _pushMediaState();
    _silentFire();
  }

  /// Notification "stop"/swipe-away: pause and drop the controls.
  Future<void> stopFromSystem() async {
    if (current == null) return;
    await _whenReady();
    _stopHold();
    _wasPlayingBeforeInterruption = false;
    await _ap!.pause();
    await PlaybackNotification.clear();
    _silentFire();
  }

  /// Engine volume, 0..1, shared by the volume slider and the speaker button.
  Future<void> setVolume(double v) async {
    await _whenReady();
    volume = v.clamp(0.0, 1.0);
    if (volume > 0) _volumeBeforeMute = volume;
    await _ap?.setVolume(volume);
    _silentFire();
  }

  /// Speaker tap: mute at 0, restore the previous level on the second tap.
  Future<void> toggleMute() =>
      setVolume(volume > 0 ? 0 : (_volumeBeforeMute > 0 ? _volumeBeforeMute : 1));

  Future<void> seek(double fraction) async {
    await _whenReady();
    final d = _ap!.duration;
    if (d != null) {
      await _ap!.seek(d * fraction);
      _noteSeek();
      _pushMediaState();
    }
  }

  /// Absolute seek from the lock-screen scrubber.
  Future<void> seekToMillis(int ms) async {
    await _whenReady();
    await _ap!.seek(Duration(milliseconds: ms));
    _noteSeek();
    _pushMediaState();
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
    _pushMediaState();
  }

  Future<void> skipPrev() async {
    await _whenReady();
    if (_ap!.position > const Duration(seconds: 3)) {
      await _ap!.seek(Duration.zero);
      _noteSeek();
      return;
    }
    // Spotify-style: restart when <3 s in; otherwise jump to the previous
    // track (wrap-around).
    final prev = (queueIndex - 1 + queue.length) % queue.length;
    if (prev == queueIndex || queue.isEmpty) {
      await _ap!.seek(Duration.zero);
      _noteSeek();
      return;
    }
    _markManualAdvance();
    try {
      await _ap!.seek(Duration.zero, index: prev);
    } catch (e, s) {
      reportError('previous failed', e, s);
      await _ap!.seek(Duration.zero);
      _noteSeek();
    }
    _pushMediaState();
  }

  void setLoop(RtLoop m) {
    loop = m;
    // Re-draw the count and re-arm per-item looping for the track in flight.
    _newTrackLoops();
    _silentFire();
  }

  /// Shuffle is on by default (ReelTunes' identity). Toggling applies from the
  /// next cycle / next play(): the queue already loaded keeps playing in the
  /// order it was dealt, so nothing in flight is interrupted.
  void toggleShuffle() {
    shuffleOn = !shuffleOn;
    _silentFire();
  }

  // ---- per-track looping -------------------------------------------------
  //
  // Why not ProcessingState.completed? Inside a playlist the platform
  // auto-advances, so "completed" only ever fires at the END of the whole
  // queue — the old counter never ran, and every track played once.
  //
  // Now: every track starts in LoopMode.one (ExoPlayer repeat-one = the
  // current item repeats exactly, gaplessly, even in the background). Passes
  // are counted from the wrap the engine performs at the boundary, and the
  // engine is switched to LoopMode.off at the START of the final pass so the
  // queue moves on at the natural boundary with no platform call racing it.
  void _newTrackLoops() {
    _played = 0;
    _endSeen = false;
    _finalPassArmed = false;
    _lastPos = _ap?.position ?? Duration.zero;
    _tickIndex = queueIndex;
    // Ticks that arrive while the new item is being prepared can jump around;
    // never read one as a wrap.
    _ignoreWrapUntil = DateTime.now().add(const Duration(milliseconds: 400));
    _targetLatched = _durationSecondsHint() > 0;
    _targetLoops = _loopsTarget();
    _armLoopMode();
  }

  void _armLoopMode() {
    final ap = _ap;
    if (ap == null) return;
    // "Play once" (and a drawn target of 1) arms the engine off from the very
    // start: no position event has to land near the end for a very short clip
    // to advance, and it keeps working when the app is backgrounded and ticks
    // are sparse.
    final single = loop != RtLoop.infinite && _targetLoops <= 1;
    _finalPassArmed = single;
    unawaited(ap.setLoopMode(single ? LoopMode.off : LoopMode.one));
  }

  /// Flips the engine off repeat-one for the pass in flight. Idempotent: the
  /// wrap counter and the end-of-clip safety both call it.
  void _armFinalPass() {
    if (_finalPassArmed) return;
    _finalPassArmed = true;
    unawaited(_ap?.setLoopMode(LoopMode.off));
  }

  void _markManualAdvance() {
    _manualAdvanceUntil = DateTime.now().add(const Duration(seconds: 1));
  }

  /// Manual seeks are not pass wraps. They land the position at the head of
  /// the clip and would otherwise look like the engine repeating the final
  /// pass (which would make the player skip ahead mid-scrub).
  void _noteSeek() {
    _ignoreWrapUntil = DateTime.now().add(const Duration(milliseconds: 700));
    _lastPos = _ap?.position ?? Duration.zero;
  }

  void _onPosition(Duration pos) {
    // A new queue row means the position is small because the track changed,
    // not because this one wrapped. `_newTrackLoops` already reset the baseline.
    if (_tickIndex != queueIndex) {
      _tickIndex = queueIndex;
      _lastPos = pos;
      return;
    }
    final last = _lastPos;
    _lastPos = pos;

    final d = _ap?.duration;
    if (d == null || d.inMilliseconds <= 0) return;
    final total = d.inMilliseconds;

    // First real duration of this track: latch the target now so Smart's
    // short-clip boost is based on the actual length.
    if (!_targetLatched) {
      _targetLoops = _loopsTarget();
      _targetLatched = true;
      if (loop != RtLoop.infinite && _targetLoops <= 1) _armFinalPass();
    }

    // Last stretch of the pass. Counting here (not on the wrap) means a missed
    // tick at the boundary can never lose a pass.
    final atTail = pos.inMilliseconds >= total - 500;
    if (atTail && !_endSeen) {
      _endSeen = true;
      _played++;
      // Fallback only: normally the final pass was armed at its start.
      if (loop != RtLoop.infinite && _played >= _targetLoops) _armFinalPass();
    }

    // The position went back to the head of the clip on the same queue row:
    // either the engine repeated it (LoopMode one) or the user scrubbed.
    final wrapped = last.inMilliseconds > total * 0.7 &&
        pos.inMilliseconds < total * 0.3 &&
        pos < last;

    if (wrapped && DateTime.now().isAfter(_ignoreWrapUntil)) {
      _ignoreWrapUntil = DateTime.now().add(const Duration(milliseconds: 800));
      // The engine repeated a pass that was already armed as the last one: the
      // platform call lost the race. Cut the replay at once instead of letting
      // the finished clip play again.
      if (_finalPassArmed) {
        _finalPassArmed = false;
        unawaited(_advanceAfterReplay());
        return;
      }
    }

    // Start of a new pass (the head of the clip, right after a wrap): if this
    // is the final one, arm the engine off NOW so nothing has to happen at the
    // boundary.
    if (pos.inMilliseconds < total * 0.3) {
      _endSeen = false;
      if (!_finalPassArmed &&
          loop != RtLoop.infinite &&
          _played + 1 >= _targetLoops) {
        _armFinalPass();
      }
    }
  }

  /// The engine wrapped a pass that should have been the last one. Move on at
  /// once so the user hears ~200 ms of the replay at most, never a full pass.
  Future<void> _advanceAfterReplay() async {
    final ap = _ap;
    if (ap == null || queue.isEmpty) return;
    try {
      if (queueIndex + 1 < queue.length) {
        await ap.seek(Duration.zero, index: queueIndex + 1);
      } else {
        await _wrapCycle();
      }
      _pushMediaState();
      _silentFire();
    } catch (e, s) {
      reportError('advance after repeat failed', e, s);
    }
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
        _finalPassArmed) {
      AppStore.I.recordLoopCount(_targetLoops);
    }
    queueIndex = i;
    current = i < queue.length ? queue[i] : null;
    final loaded = current;
    if (loaded != null) AppStore.I.setLastPlayedId(loaded.id);
    _newTrackLoops();
    _pushMediaState();
    _silentFire();
  }

  /// Queue exhausted (last pass of the last item). Start a fresh cycle instead
  /// of stopping dead — playback here is an endless reel loop.
  Future<void> _onPlaylistEnd() async {
    // A removal can push the engine into "completed" while `queue` is being
    // rebuilt — that is not the end of the queue, so don't seek to the top.
    if (_queueSurgery) return;
    if (!queuePlayable) return;
    // The last queue item ends here instead of an index change — record its
    // custom-range completion before wrapping (same Smart-learning signal).
    if (loop == RtLoop.customRange &&
        _targetLoops > 0 &&
        _finalPassArmed) {
      AppStore.I.recordLoopCount(_targetLoops);
    }
    _markManualAdvance();
    await _wrapCycle();
    _pushMediaState();
    _silentFire();
  }

  /// Restarts the queue from its first item. With shuffle on, the next cycle is
  /// a brand-new permutation (reloaded, since the engine's own order can only
  /// be replaced by loading a new source list). With one audio, or shuffle
  /// off, it is the same order replayed — no reload, so the join is gapless.
  Future<void> _wrapCycle() async {
    final ap = _ap;
    if (ap == null || queue.isEmpty) return;
    if (_wrapping) return;
    _wrapping = true;
    try {
      if (!shuffleOn || queue.length < 2) {
        try {
          await ap.seek(Duration.zero, index: 0);
          queueIndex = 0;
          current = queue.first;
          _newTrackLoops();
          unawaited(ap.play());
        } catch (e, s) {
          reportError('wrap-around failed', e, s);
        }
        return;
      }
      queue = _nextCycle(queue, current?.id);
      queueIndex = 0;
      current = queue.first;
      await _startCurrent();
    } finally {
      _wrapping = false;
    }
  }

  /// Audio-focus interruptions (calls, alarms, other apps).
  ///
  /// Pausing is the default. With "Keep playing during calls" on, playback is
  /// held through a pause-type interruption instead: `play()` is retried until
  /// the call is over, because a single call can be rejected while the call UI
  /// owns focus (which made the audio go silent for the rest of the track and
  /// only come back on the NEXT one).
  ///
  /// Nothing ever resumes on its own when an interruption ends. That automatic
  /// resume was the "audio starts playing after I close reels" bug: another app
  /// going quiet must leave the player exactly as the user left it.
  void _onInterruption(asess.AudioInterruptionEvent e) {
    if (e.begin) {
      _wasPlayingBeforeInterruption = playing;
      // A duck (notification sound, navigation prompt) never pauses. The OS
      // lowers the whole media stream while the other app holds transient
      // focus. Unless the user allowed that dip, take focus straight back so
      // the volume never drops.
      if (e.type == asess.AudioInterruptionType.duck) {
        if (!AppStore.I.lowerVolumeForOtherAudio) unawaited(_reclaimFocus());
        return;
      }
      if (!AppStore.I.playDuringCalls) {
        _ap?.pause();
        return;
      }
      // Only defend a pass that was really in flight — a player the user
      // paused must never start by itself, call or not.
      if (_wasPlayingBeforeInterruption) _holdThroughInterruption();
      return;
    }
    _stopHold();
    _wasPlayingBeforeInterruption = false;
  }

  /// Cancels a duck by dropping and immediately re-requesting audio focus.
  ///
  /// audio_session returns early when a focus request is already held, so a
  /// plain `setActive(true)` is a no-op. Releasing first and asking again with
  /// GAIN makes the other app lose its transient focus, which ends the duck
  /// bundle; the engine never pauses, so the position is untouched.
  bool _reclaiming = false;
  Future<void> _reclaimFocus() async {
    if (_reclaiming) return;
    _reclaiming = true;
    try {
      final session = await asess.AudioSession.instance;
      await session.setActive(false);
      if (current == null) return;
      await session.setActive(
        true,
        androidAudioFocusGainType: asess.AndroidAudioFocusGainType.gain,
      );
      // Some OEMs hand focus back but leave the stream ducked for a moment;
      // re-asserting play is enough to make the engine push its current volume.
      if (!playing) unawaited(_ap?.play());
    } catch (_) {
      // Focus is best-effort: the music keeps playing either way.
    } finally {
      _reclaiming = false;
    }
  }

  void _holdThroughInterruption() {
    _callHold?.cancel();
    void reassert() {
      final ap = _ap;
      if (ap == null || current == null) return;
      if (!ap.playing) unawaited(ap.play());
    }

    reassert();
    _callHold = Timer.periodic(
        const Duration(milliseconds: 700), (_) => reassert());
  }

  void _stopHold() {
    _callHold?.cancel();
    _callHold = null;
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
      if (current == null) {
        unawaited(PlaybackNotification.clear());
      } else {
        _pushMediaState();
      }
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
