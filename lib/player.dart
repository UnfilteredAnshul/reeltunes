// Playback engine: just_audio (+ just_audio_background) + ReelTune's
// advanced looping. One process-wide player; the app always plays the same
// track. Background playback / lock-screen & media widget come from
// just_audio_background (MediaSession with MediaItem tags per track).

import 'dart:math';

import 'package:audio_session/audio_session.dart' as asess;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'models.dart';

class RtPlayer extends ChangeNotifier {
  RtPlayer._() {
    _ap.playerStateStream.listen(_onState);
    // Manual interruption handling via audio_session (just_audio 0.10.x has
    // no public interruption stream) so "keep playing during calls" works.
    asess.AudioSession.instance.then((session) {
      session.interruptionEventStream.listen(_onInterruption);
      session.becomingNoisyEventStream.listen((_) => _ap.pause());
    });
    // Notification / media-widget driven index changes stay in sync here.
    _ap.currentIndexStream.listen((i) {
      if (i == null || !queuePlayable || i == queueIndex) return;
      queueIndex = i;
      current = queue[i];
      _loopsDone = 0;
      _targetLoops = _loopsTarget();
      _silentFire();
    });
  }
  static final RtPlayer I = RtPlayer._();

  final AudioPlayer _ap = AudioPlayer(handleInterruptions: false);

  Track? current;
  List<Track> queue = [];
  int queueIndex = -1;

  /// Advanced looping: smart or custom-range. Shuffle is always on by design.
  RtLoop loop = RtLoop.smart;
  bool shuffleOn = true;

  bool _wasPlayingBeforeInterruption = false;
  int _targetLoops = 1;
  int _loopsDone = 0;
  bool get playing => _ap.playing && current != null;
  bool get queuePlayable => queue.isNotEmpty && queueIndex >= 0;

  // ---- streams for UI ----
  Stream<Duration> get positionStream => _ap.positionStream;
  Stream<Duration?> get durationStream => _ap.durationStream;
  Duration? get duration => _ap.duration;

  /// Fisher-Yates with a fresh RNG per call, then move the tapped track to
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

  Future<void> play(Track t, {List<Track>? context}) async {
    var ctx = context ?? queue;
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
      await _ap.setAudioSource(
        ConcatenatingAudioSource(children: sources),
        initialIndex: queueIndex.clamp(0, sources.length - 1),
      );
      await _ap.play();
    } catch (e) {
      debugPrint('play failed: $e');
      // Skip a broken file instead of hanging the queue.
      skipNext();
    }
    _silentFire();
  }

  int _loopsTarget() {
    final store = AppStore.I;
    var min = store.rangeMin;
    var max = store.rangeMax;
    if (loop == RtLoop.smart) {
      // Smart: short reels loop a bit more; still bounded by the user's range.
      final secs = (_ap.duration?.inSeconds ?? 0);
      if (secs < 30) {
        min = (min).clamp(1, 999);
        max = (max + 1).clamp(min, 999);
      }
    }
    return randomLoopCount(min, max);
  }

  void toggle() {
    if (current == null) return;
    _ap.playing ? _ap.pause() : _ap.play();
    _silentFire();
  }

  Future<void> seek(double fraction) async {
    final d = _ap.duration;
    if (d != null) await _ap.seek(d * fraction);
  }

  void skipNext() {
    if (queue.isEmpty) return;
    queueIndex = (queueIndex + 1) % queue.length;
    _startCurrent();
  }

  void skipPrev() => _ap.position > const Duration(seconds: 3)
      ? _ap.seek(Duration.zero)
      : null;

  void setLoop(RtLoop m) {
    loop = m;
    _loopsDone = 0;
    _targetLoops = _loopsTarget();
    _silentFire();
  }

  /// Completed-state steering: track plays _targetLoops times, then next
  /// track (which draws its own count).
  void _onState(PlayerState s) {
    if (s.processingState != ProcessingState.completed) return;
    _loopsDone++;
    if (_loopsDone < _targetLoops) {
      _ap.seek(Duration.zero).then((_) => _ap.play());
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
        _ap.pause();
      } else {
        // Keep going — re-assert play with fresh focus.
        _ap.play();
      }
    } else {
      if (_wasPlayingBeforeInterruption && !AppStore.I.playDuringCalls) {
        _ap.play();
      }
    }
  }

  /// If the playing track was deleted from the library, stop gracefully.
  void removeIfCurrent(String id) {
    if (current?.id == id) {
      _ap.stop();
      current = null;
      queueIndex = -1;
      notifyListeners();
    }
  }

  void _silentFire() => notifyListeners();
}

// A per-process salt so seed differs even if the epoch micros ever collide
const int DartHashSeedRandomSalt = 0x5f4d9e17;
