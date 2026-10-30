package com.reeltune.app.reel_tune

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.android.FlutterActivity

// AudioServiceActivity is REQUIRED by just_audio_background: it wires the
// Flutter engine to the media session service. Without it, init() fails on
// the platform side and every play() throws LateInitializationError.
class MainActivity : AudioServiceActivity()
