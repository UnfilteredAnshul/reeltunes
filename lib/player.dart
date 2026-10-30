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
  int _loopsDone = 0;
  /// Consecutive failed loads. Broken files are skipped, but if EVERY file
  /// fails we must stop instead of looping forever (that loop was the
  /// "crashes 2 s after tapping play").
  int _loadFailures = 0;
  bool get queuePlayable => queue.isNotEmpty && queueIndex >= 0;

  bool get playing {
    final ap = _ap;
    return _booted && ap != null && ap.playing && current != null;
  }

  /// Media-session service setup + player creation. Started right after
  /// runApp() — never blocks the app launch.
  Future<void> ensureBackgroundService() =>
      _bgInit ??= JustAudioBackground.init(
        androidNotificationChannelId: 'com.reeltune.app.reel_tune.playback',
        androidNotificationChannelName: 'ReelTunes playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      );

  Future<void> _boot() async {
    try {
      await ensureBackgroundService();
    } catch (e, s) {
      // Media session unavailable — degrade to plain in-app playback.
      reportError('media session init failed', e, s);
    }
    final ap = AudioPlayer(handleInterruptions: false);
    ap.playerStateStream.listen(_onState);
    // Manual interruption handling via audio_session (just_audio 0.10.x has
    // no public interruption stream) so "keep playing during calls" works.
    asess.AudioSession.instance.then((session) {
      session.interruptionEventStream.listen(_onInterruption);
      session.becomingNoisyEventStream.listen((_) => ap.pause());
    });
    // Notification / media-widget driven index changes stay in sync here.
    ap.currentIndexStream.listen((i) {
      if (i == null || !queuePlayable || i == queueIndex) return;
      queueIndex = i;
      current = queue[i];
      _loopsDone = 0;
      _targetLoops = _loopsTarget();
      _silentFire();
    });
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
    _loopsDone = 0;
    _targetLoops = _loopsTarget();
    _silentFire();
    try {
      final sources = <AudioSource>[
        for (final q in queue)
          AudioSource.file(
            q.path,
            tag: MediaItem(
              id: q.id,
              title: q.title,
              artist: q.source,
              duration: q.durationMs > 0
                  ? Duration(milliseconds: q.durationMs)
                  : null,
            ),
          ),
      ];
      await _ap!.setAudioSource(
        ConcatenatingAudioSource(children: sources),
        initialIndex: queueIndex.clamp(0, sources.length - 1),
      );
      await _ap!.play();
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

  int _loopsTarget() {
    final store = AppStore.I;
    var min = store.rangeMin;
    var max = store.rangeMax;
    if (loop == RtLoop.smart) {
      // Smart: short reels loop a bit more; still bounded by the user's range.
      final secs = (_booted ? _ap!.duration?.inSeconds : null) ?? 0;
      if (secs < 30) {
        min = (min).clamp(1, 999);
        max = (max + 1).clamp(min, 999);
      }
    }
    return randomLoopCount(min, max);
  }

  Future<void> toggle() async {
    if (current == null) return;
    await _whenReady();
    _ap!.playing ? await _ap!.pause() : await _ap!.play();
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
    try {
      await _ap!.seek(Duration.zero, index: prev);
    } catch (e, s) {
      reportError('previous failed', e, s);
      await _ap!.seek(Duration.zero);
    }
  }

  void setLoop(RtLoop m) {
    loop = m;
    _loopsDone = 0;
    _targetLoops = _loopsTarget();
    _silentFire();
  }

  /// Shuffle is on by default (ReelTunes' identity). Toggling it only
  /// changes the order used by the NEXT play()/queue build — the current
  /// queue keeps playing untouched.
  void toggleShuffle() {
    shuffleOn = !shuffleOn;
    _silentFire();
  }

  /// Completed-state steering: track plays _targetLoops times, then next
  /// track (which draws its own count). Infinite loop = forever, never
  /// advancing — the plain "loop like normal music apps" behavior.
  void _onState(PlayerState s) {
    if (s.processingState != ProcessingState.completed) return;
    _loopsDone++;
    if (_loopsDone < _targetLoops || loop == RtLoop.infinite) {
      _ap!.seek(Duration.zero).then((_) => _ap!.play());
    } else {
      skipNext();
    }
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

  /// If the playing track was deleted from the library, stop gracefully.
  void removeIfCurrent(String id) {
    if (current?.id != id) return;
    if (_booted) _ap!.stop();
    current = null;
    queueIndex = -1;
    notifyListeners();
  }

  void _silentFire() => notifyListeners();
}

// A per-process salt so seed differs even if the epoch micros ever collide
const int DartHashSeedRandomSalt = 0x5f4d9e17;
