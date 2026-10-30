// Dev-phase error surfacing: anything failing gets BOTH the logcat dump and
// an on-screen floating toast (snackbar) so runtime problems are visible on
// the device. Superseded by polished UX after the dev phase.
//
// CRITICAL: error handlers run *inside* frame dispatch. Showing UI work
// synchronously from here re-enters the scheduler and freezes the app
// (the "_FrameCallbackEntry.debugCurrentCallbackStack == null" wedge).
// So: toast via microtask + one-toast-at-a-time guard.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Attach to MaterialApp.scaffoldMessengerKey so everywhere can toast.
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

bool _toastInFlight = false;

void reportError(String context, Object error, StackTrace? stack) {
  final full = context.isEmpty ? '$error' : '$context: $error';
  debugPrint('⚠️ $full\n${stack ?? ''}');
  if (_toastInFlight) return; // error storms show one toast, not a cascade
  _toastInFlight = true;
  Future<void>.microtask(() async {
    try {
      rootMessengerKey.currentState?.showSnackBar(SnackBar(
        content:
            Text(full.length > 400 ? '${full.substring(0, 400)}…' : full),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 10),
      ));
      // spacing so consecutive problems don't overwrite instantly
      await Future<void>.delayed(const Duration(seconds: 1));
    } catch (_) {
      // never report errors from the error reporter
    }
  }).whenComplete(() => _toastInFlight = false);
}

void installErrorReporting() {
  FlutterError.onError = (details) {
    reportError('flutter error', details.exception, details.stack);
    FlutterError.presentError(details); // keep the red-detail console dump
  };
  PlatformDispatcher.instance.onError = (e, s) {
    reportError('uncaught error', e, s);
    return true;
  };
}
