/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:collection';
import 'dart:ffi';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/core/execmem_restriction.dart';
import 'package:media_kit/src/player/native/core/initializer_isolate.dart';
import 'package:synchronized/synchronized.dart';

typedef WakeUpCallback = Void Function(Pointer<generated.mpv_handle>);
typedef WakeUpNativeCallable = NativeCallable<WakeUpCallback>;
typedef WakeUpNativeCallableMap = HashMap<int, WakeUpNativeCallable>;

typedef EventCallback = Future<void> Function(Pointer<generated.mpv_event>);
typedef EventCallbackMap = HashMap<int, EventCallback>;

/// {@template initializer}
///
/// Initializer
/// -----------
/// Initializes [Pointer<mpv_handle>] & notifies about events through the supplied callback.
///
/// {@endtemplate}
class Initializer {
  /// Singleton instance.
  static Initializer? _instance;

  /// {@macro initializer}
  Initializer._(this.mpv);

  /// {@macro initializer}
  factory Initializer(generated.MPV mpv) {
    _instance ??= Initializer._(mpv);
    return _instance!;
  }

  /// Generated libmpv C API bindings.
  final generated.MPV mpv;

  /// Creates [Pointer<mpv_handle>].
  Future<Pointer<generated.mpv_handle>> create(
    Future<void> Function(Pointer<generated.mpv_event>) callback, {
    Map<String, String> options = const {},
  }) async {
    if (isExecmemRestricted) {
      // If creating executable memory is restricted on Linux, Dart VM will crash when trying to use NativeCallables.
      // Fallback to the isolate-based event loop approach if that's the case.
      return InitializerIsolate.create(
        callback,
        options
      );
    } else {
      final ctx = mpv.mpv_create();
      for (final entry in options.entries) {
        final name = entry.key.toNativeUtf8();
        final value = entry.value.toNativeUtf8();
        mpv.mpv_set_option_string(ctx, name.cast(), value.cast());
        calloc.free(name);
        calloc.free(value);
      }
      mpv.mpv_initialize(ctx);
      final nativeCallable = WakeUpNativeCallable.listener(_callback);
      final nativeFunction = nativeCallable.nativeFunction;
      _locks[ctx.address] = Lock();
      _eventCallbacks[ctx.address] = callback;
      _wakeUpNativeCallables[ctx.address] = nativeCallable;
      mpv.mpv_set_wakeup_callback(ctx, nativeFunction.cast(), ctx.cast());
      return ctx;
    }
  }

  /// Disposes [Pointer<mpv_handle>].
  void dispose(Pointer<generated.mpv_handle> ctx) {
    if (isExecmemRestricted) {
      InitializerIsolate.dispose(mpv, ctx);
    } else {
      _locks.remove(ctx.address);
      _eventCallbacks.remove(ctx.address);
      _wakeUpNativeCallables.remove(ctx.address)?.close();
    }
  }

  void _callback(Pointer<generated.mpv_handle> ctx) {
    _locks[ctx.address]?.synchronized(() async {
      while (true) {
        final event = mpv.mpv_wait_event(ctx, 0);
        if (event == nullptr) return;
        if (event.ref.event_id == generated.mpv_event_id.MPV_EVENT_NONE) return;
        await _eventCallbacks[ctx.address]?.call(event);
      }
    });
  }

  final _locks = HashMap<int, Lock>();
  final _eventCallbacks = EventCallbackMap();
  final _wakeUpNativeCallables = WakeUpNativeCallableMap();
}
