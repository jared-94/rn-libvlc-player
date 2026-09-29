/**
 * Port of RnLibvlcPlayerView.java (Android) to iOS/VLCKit. Behavior is meant
 * to mirror the Android implementation exactly (same event names/payloads,
 * same autoplay-vs-paused semantics, same stall watchdog, same
 * always-populate-aspectRatio-or-empty-string guard on onVideoLoad) — see
 * that file's comments for the reasoning behind each of these, most of which
 * came out of an on-device debugging session against a live RTSP source.
 *
 * Built against VLCKit 4.x (not MobileVLCKit 3.x). Switched after extensive
 * on-device debugging traced a persistent "plays briefly, then flaps
 * Playing<->Buffering forever, then goes silent until our own watchdog
 * force-reconnects" symptom to MobileVLCKit 3.x's architecture itself:
 * buffering is one of the states in VLCMediaPlayerState there, so any
 * buffering blip forces the player's overall state OUT of Playing and back
 * — repeatedly, for a live RTSP feed with normal jitter. VLCKit 4.x's
 * VLCMediaPlayerDelegate has a *separate* -mediaPlayerBufferingChanged:
 * callback (0.0...1.0) that doesn't touch -mediaPlayerStateChanged: at all;
 * -mediaPlayerStateChanged: only reports Playing/Paused/Stopped/Error, and
 * VLCMediaPlayerStateBuffering doesn't exist as a case anymore. Confirmed
 * via VLCKit's own header doc: "this is always called with 0.0 and 1.0
 * before a successful playback" — a clean, guaranteed pair, unlike 3.x's
 * mixed-into-state-machine buffering signal.
 */

#import "RnLibvlcPlayerView.h"

#import <react/renderer/components/rnlibvlcplayer/ComponentDescriptors.h>
#import <react/renderer/components/rnlibvlcplayer/EventEmitters.h>
#import <react/renderer/components/rnlibvlcplayer/Props.h>
#import <react/renderer/components/rnlibvlcplayer/RCTComponentViewHelpers.h>

#import <React/RCTConversions.h>
#import <React/RCTFabricComponentsPlugins.h>

#import <VLCKit/VLCKit.h>

using namespace facebook::react;

static const NSTimeInterval kDefaultProgressUpdateIntervalMs = 250;
// See RnLibvlcPlayerView.java's STALL_THRESHOLD_MS javadoc: libVLC's own
// delegate can go silent (no further callback at all, buffering or
// otherwise) if a live RTSP stream freezes mid-playback instead of cleanly
// stopping — currentTime simply stops advancing while isPlaying keeps
// reporting true. VLCKit 4.x's split buffering/state delegates fix the
// "flapping" symptom, but not this different failure mode, so the watchdog
// stays: detect it ourselves and synthesize a low-bufferRate event so a
// consumer's existing auto-reload logic (typically an onBuffering handler)
// has something to react to.
static const NSTimeInterval kStallThresholdMs = 2500;

@interface RnLibvlcPlayerView () <RCTRnLibvlcPlayerViewViewProtocol, VLCMediaPlayerDelegate>
@end

@implementation RnLibvlcPlayerView {
  VLCLibrary *_library;
  VLCMediaPlayer *_player;
  BOOL _isPaused;
  BOOL _isReleased;
  BOOL _wasPlayingBeforeBackground;

  // Source props: any change tears the player down and rebuilds it once
  // (see updateProps:oldProps: — Fabric hands us the whole props diff for a
  // commit in one call, so unlike Android there's no need for a separate
  // "batch complete" hook to avoid rebuilding once per individual prop).
  NSString *_uri;
  BOOL _isNetworkProp;
  BOOL _autoplayProp;
  NSInteger _initType;
  BOOL _hwDecoderEnabled;
  BOOL _hwDecoderForced;
  NSArray<NSString *> *_initOptions;

  // Playback-control props: applied directly to the live player, no rebuild.
  BOOL _pausedProp;
  BOOL _mutedProp;
  BOOL _autoAspectRatioProp;
  NSString *_videoAspectRatioProp;
  NSTimeInterval _progressUpdateIntervalMs;

  NSTimer *_progressTimer;
  double _lastProgressCurrentTime;
  NSTimeInterval _stalledSinceMs;
  // Whether we've told JS "buffering" (bufferRate:0) for the stall
  // currently being tracked — lets us tell it "resolved" (bufferRate:100)
  // once currentTime resumes advancing. Without this, a stall that self-
  // resolves (normal RTSP network jitter) leaves the JS-side spinner stuck
  // forever: nothing else clears it (see kStallThresholdMs comment above).
  BOOL _hasReportedStall;

  NSString *_videoInfoHash;

  // Guards against an unbounded pile-up of native players/threads when a
  // source stalls at the network level (confirmed on-device: a demux thread
  // blocked forever in a socket read, with no VLC-level timeout — see
  // releasePlayer's background-queue comment). -stop can then take
  // arbitrarily long to return, but nothing previously stopped
  // rebuildPlayerWithAutoplay: from constructing ANOTHER player in the
  // meantime (every ~10s, per the JS reload watchdog) — each one blocking
  // its own demux thread the same way, none of which the serial teardown
  // queue could ever catch up on. Tracked here instead so a new rebuild
  // waits for the in-flight teardown to actually finish first.
  BOOL _teardownInFlight;
  BOOL _hasPendingRebuild;
  BOOL _pendingRebuildAutoplay;
}

+ (void)load
{
  [super load];
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const RnLibvlcPlayerViewProps>();
    _props = defaultProps;

    _isPaused = YES;
    _isReleased = YES;
    _lastProgressCurrentTime = -1;
    _stalledSinceMs = 0;
    _hasReportedStall = NO;
    _progressUpdateIntervalMs = kDefaultProgressUpdateIntervalMs;
    _initType = 1;
    _initOptions = @[];
    _uri = @"";
    _videoAspectRatioProp = @"";

    // Added once here, removed once in dealloc — NOT in the per-source
    // rebuild path. The old iOS library removed+never-restored these
    // observers on every setSource: call after the first one, silently
    // breaking background/foreground handling after any URL change.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(applicationWillResignActive:)
                                                  name:UIApplicationWillResignActiveNotification
                                                object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(applicationDidBecomeActive:)
                                                  name:UIApplicationDidBecomeActiveNotification
                                                object:nil];
  }
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - App state (mirrors Android's onHostPause/onHostResume)

- (void)applicationWillResignActive:(NSNotification *)notification
{
  if (_player != nil && !_isPaused && _player.isPlaying) {
    [_player pause];
    _wasPlayingBeforeBackground = YES;
  } else {
    _wasPlayingBeforeBackground = NO;
  }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
  if (_player != nil && _wasPlayingBeforeBackground && !_pausedProp) {
    [_player play];
    _wasPlayingBeforeBackground = NO;
  }
}

#pragma mark - Layout (autoAspectRatio uses the view's own bounds, like Android's onLayoutChangeListener)

- (void)layoutSubviews
{
  [super layoutSubviews];
  if (_player != nil && _autoAspectRatioProp) {
    CGSize size = self.bounds.size;
    if (size.width > 0 && size.height > 0) {
      _player.videoAspectRatio = [NSString stringWithFormat:@"%d:%d", (int)size.width, (int)size.height];
    }
  }
  // VLCKit 4.x installs its own video-rendering subview into `self` once
  // `_player.drawable = self` is set, and that subview doesn't reliably
  // keep pace with Fabric-driven bounds changes on `self` (unlike
  // MobileVLCKit 3.x) — confirmed on-device: a thin black band appears
  // where the container grew after the real aspect ratio replaced the
  // initial DEFAULT_ASPECT_RATIO-sized guess, and only a full window
  // relayout (e.g. backgrounding/foregrounding the app) ever caught it up.
  // Force it explicitly on every layout pass instead of relying on
  // VLCKit's own (apparently unreliable) autoresizing.
  // Only touch subviews whose frame is actually stale — layoutSubviews can
  // fire very frequently (progress ticks, scroll, etc.) and unconditionally
  // reassigning frame on every pass forces VLCKit to redo internal surface
  // setup each time, which may be adding contention on top of an
  // already-stressed decoder pipeline for demanding streams.
  for (UIView *subview in self.subviews) {
    if (!CGRectEqualToRect(subview.frame, self.bounds)) {
      subview.frame = self.bounds;
    }
  }
}

#pragma mark - Player lifecycle

// Converts our shared "--option" / "--option=value" strings (used verbatim
// by Android's LibVLC(context, options) engine-level constructor) into the
// ":option" / ":option=value" form VLCMedia addOption: expects — VLCKit 4.x
// applies options per-media, not at the engine/library level like 3.x's
// VLCMediaPlayer initWithOptions: did, so this now has to happen per source
// rebuild rather than once at player construction.
static NSString *RNLibvlcNormalizeOption(NSString *option)
{
  if ([option hasPrefix:@":"]) {
    return option;
  }
  NSUInteger i = 0;
  while (i < option.length && [option characterAtIndex:i] == '-') {
    i++;
  }
  return [@":" stringByAppendingString:[option substringFromIndex:i]];
}

- (void)rebuildPlayerWithAutoplay:(BOOL)autoplay
{
  [self releasePlayer];

  // A previous teardown's -stop is still running in the background (see
  // releasePlayer) — most likely blocked on a stalled network read that may
  // never return on its own. Building a new player now would just pile
  // another one on top, each with its own threads that can never be
  // reclaimed. Defer: releasePlayer's completion handler re-invokes this
  // once the in-flight teardown actually finishes.
  if (_teardownInFlight) {
    _hasPendingRebuild = YES;
    _pendingRebuildAutoplay = autoplay;
    return;
  }

  _lastProgressCurrentTime = -1;
  _stalledSinceMs = 0;
  _hasReportedStall = NO;
  _videoInfoHash = nil;

  if (_uri.length == 0) {
    return;
  }

  // initType distinguished "engine with no options" vs "engine constructed
  // with options" under MobileVLCKit 3.x's initWithOptions: pattern — moot
  // now that options are always applied per-media below, but the prop stays
  // for cross-platform parity (Android still branches on it).
  (void)_initType;

  _library = [[VLCLibrary alloc] init];
  _player = [[VLCMediaPlayer alloc] initWithLibrary:_library];
  _player.delegate = self;
  _player.drawable = self;
  // videoFitMode is new in VLCKit 4.x (didn't exist in MobileVLCKit 3.x,
  // which always stretched video to exactly fill the given drawable). Its
  // default preserves the video's own aspect ratio inside the drawable
  // instead — confirmed on-device: a thin black letterbox band appeared
  // above the video after the 4.x migration, on every camera, matching this
  // exactly. JS already sizes the container from the reported aspect ratio
  // (see videoPlayer.js's setAspectRatio), so let VLCKit fill the exact
  // bounds it's given rather than double-letterboxing on top of that.
  _player.videoFitMode = VLCVideoFitNone;
  _player.scaleFactor = 0;

  // hwDecoderEnabled/hwDecoderForced are accepted for cross-platform prop
  // parity with Android but are currently a no-op here: VLCKit uses
  // VideoToolbox hardware decoding automatically when available, and there's
  // no confirmed-stable per-media API to force/disable it (unlike Android's
  // Media.setHWDecoderEnabled). Revisit only if a real stream needs it
  // disabled — toggling it made no observable difference during the Android
  // debugging session either.
  (void)_hwDecoderEnabled;
  (void)_hwDecoderForced;

  NSURL *url = [NSURL URLWithString:_uri];
  VLCMedia *media = [VLCMedia mediaWithURL:url];
  for (NSString *option in _initOptions) {
    [media addOption:RNLibvlcNormalizeOption(option)];
  }
  _player.media = media;

  [self applyMutedModifier:_mutedProp];
  [self applyAspectRatioIfNeeded];

  if (autoplay) {
    [_player play];
    _isPaused = NO;
  } else {
    _isPaused = YES;
  }

  [self emitLoadStart];
  [self startProgressTimerIfNeeded];
  _isReleased = NO;
}

- (void)releasePlayer
{
  if (_player == nil) {
    return;
  }
  [self stopProgressTimer];

  // -stop synchronously on the main thread is dangerous under VLCKit 4.0a23:
  // confirmed on-device (repeated "creating player instance..." log bursts
  // ~10s apart, matching the JS reload watchdog, then the OS SIGKILLing the
  // app for main-thread unresponsiveness) that calling -stop on a player
  // that's still mid-connection (never reached Playing — exactly the case
  // every time our own stall/reload watchdog fires) can block indefinitely,
  // apparently deadlocking against VLCKit's internal thread trying to
  // deliver a delegate callback back onto the same main thread. So: detach
  // everything that touches `self` synchronously (delegate/drawable, ivars)
  // so Fabric's rebuild-on-next-updateProps: logic keeps working immediately
  // and no further callback can reach a half-torn-down view, then hand the
  // actual -stop + dealloc to a background queue where a hang no longer
  // freezes the app or trips the watchdog. Serial queue: keeps teardown
  // ordering sane if reload() fires again before a prior -stop finishes.
  VLCMediaPlayer *playerToStop = _player;
  VLCLibrary *libraryToRelease = _library;
  playerToStop.delegate = nil;
  playerToStop.drawable = nil;
  _player = nil;
  _library = nil;
  _isReleased = YES;
  _teardownInFlight = YES;

  static dispatch_queue_t sTeardownQueue;
  static dispatch_once_t sTeardownQueueOnce;
  dispatch_once(&sTeardownQueueOnce, ^{
    sTeardownQueue = dispatch_queue_create("com.rnlibvlcplayer.teardown", DISPATCH_QUEUE_SERIAL);
  });
  __weak __typeof(self) weakSelf = self;
  dispatch_async(sTeardownQueue, ^{
    @try {
      [playerToStop stop];
    } @catch (NSException *exception) {
      // Mirrors Android's defensive try/catch-per-teardown-step in
      // releasePlayer() — VLCKit teardown during an active RTSP session has
      // been just as prone to noisy-but-harmless exceptions there.
    }
    // playerToStop/libraryToRelease captured strongly by the block; letting
    // the block end (here, off the main thread) is what actually drops the
    // last reference and triggers dealloc.
    (void)libraryToRelease;
    dispatch_async(dispatch_get_main_queue(), ^{
      __typeof(self) strongSelf = weakSelf;
      if (strongSelf == nil) {
        return;
      }
      strongSelf->_teardownInFlight = NO;
      if (strongSelf->_hasPendingRebuild) {
        strongSelf->_hasPendingRebuild = NO;
        [strongSelf rebuildPlayerWithAutoplay:strongSelf->_pendingRebuildAutoplay];
      }
    });
  });
}

- (void)prepareForRecycle
{
  // Fabric's view-recycling pool calls this whenever the view is detached —
  // not just on a real unmount, but also on ordinary in-app navigation
  // (react-native-screens freezes/detaches an inactive screen's views) and
  // on JS-driven reload() (which unmounts then remounts to force a fresh
  // connection after a stall). _props survives recycling, so a same-URI
  // updateProps: right after this would normally look like "nothing
  // changed" — an earlier version of this method left _player alive across
  // recycling specifically to avoid disrupting it in that case, but that
  // broke JS's reload(): with the player never torn down, sourceChanged
  // stayed NO and the rebuild JS was explicitly asking for silently never
  // happened. Confirmed on-device: streams stuck retrying forever on their
  // own fixed interval, video never recovering, because every reload()
  // attempt was a no-op here.
  //
  // So: DO tear the player down. updateProps:'s `_player == nil` fallback
  // (see needsPlayer below) then guarantees a rebuild on the very next
  // props update regardless of whether the URI changed — correct for both
  // JS's explicit reload() and Fabric recycling a still-relevant view during
  // ordinary navigation (where a guaranteed-fresh connection beats trusting
  // a stream that may have silently degraded while off-screen).
  [self releasePlayer];
  [super prepareForRecycle];
}

#pragma mark - Prop appliers

- (void)applyPausedModifier:(BOOL)paused
{
  _pausedProp = paused;
  if (_player == nil) {
    return;
  }
  if (paused) {
    _isPaused = YES;
    [_player pause];
  } else {
    _isPaused = NO;
    [_player play];
  }
}

- (void)applyMutedModifier:(BOOL)muted
{
  _mutedProp = muted;
  if (_player != nil) {
    // VLCAudio has a real `muted` toggle on iOS (confirmed from the old
    // library's `[[_player audio] setMuted:value]`) — no need for Android's
    // save-volume/restore-volume dance, which was only necessary there
    // because libvlc-android's MediaPlayer has no direct mute flag.
    _player.audio.muted = muted;
  }
}

- (void)applyVolumeModifier:(double)volume
{
  if (_player != nil) {
    _player.audio.volume = (NSInteger)volume;
  }
}

- (void)applyRateModifier:(double)rate
{
  if (_player != nil) {
    [_player setRate:(float)rate];
  }
}

- (void)applyAspectRatioIfNeeded
{
  if (_player == nil || _autoAspectRatioProp) {
    // autoAspectRatio is handled continuously by layoutSubviews instead.
    return;
  }
  if (_videoAspectRatioProp.length > 0) {
    _player.videoAspectRatio = _videoAspectRatioProp;
  }
}

#pragma mark - Commands (RCTRnLibvlcPlayerViewViewProtocol)

- (void)seek:(double)position
{
  if (_player != nil && position >= 0 && position <= 1) {
    _player.position = (float)position;
  }
}

- (void)resume:(BOOL)autoPlay
{
  // Full rebuild, matching Android's Commands.resume -> doResume ->
  // createPlayer(autoPlay, true) contract, not the old iOS library's weaker
  // play/pause-only `resume` prop — the same command name should mean the
  // same thing on both platforms. Note: a consumer scrub-seeking should
  // prefer the `paused` prop instead, to avoid throwing away the seek
  // position a rebuild would cause — this stays available as a "hard
  // reconnect" primitive.
  [self rebuildPlayerWithAutoplay:autoPlay];
}

- (void)handleCommand:(const NSString *)commandName args:(const NSArray *)args
{
  RCTRnLibvlcPlayerViewHandleCommand(self, commandName, args);
}

#pragma mark - Progress timer / stall watchdog / onVideoLoad

- (void)startProgressTimerIfNeeded
{
  if (_progressTimer != nil || _player == nil) {
    return;
  }
  NSTimeInterval intervalSeconds = MAX(_progressUpdateIntervalMs, 1) / 1000.0;
  // `typeof` (no underscores) is a GNU C extension, not valid in strict
  // C++20 — this file is Objective-C++ compiled with CLANG_CXX_LANGUAGE_
  // STANDARD=c++20, so it needs the vendor-extension spelling instead.
  __weak __typeof(self) weakSelf = self;
  _progressTimer = [NSTimer scheduledTimerWithTimeInterval:intervalSeconds
                                                     repeats:YES
                                                       block:^(NSTimer *_Nonnull timer) {
                                                         [weakSelf progressTick];
                                                       }];
  [[NSRunLoop mainRunLoop] addTimer:_progressTimer forMode:NSRunLoopCommonModes];
}

- (void)stopProgressTimer
{
  [_progressTimer invalidate];
  _progressTimer = nil;
}

- (void)progressTick
{
  if (_player == nil || _isPaused) {
    _stalledSinceMs = 0;
    _lastProgressCurrentTime = -1;
    _hasReportedStall = NO;
    return;
  }

  BOOL isPlaying = _player.isPlaying;
  double currentTime = (double)_player.time.value.doubleValue;
  double position = _player.position;
  double duration = (double)_player.media.length.value.doubleValue;

  [self checkStallWatchdogWithIsPlaying:isPlaying currentTime:currentTime];
  [self updateVideoInfo];
  [self emitProgressWithIsPlaying:isPlaying position:position currentTime:currentTime duration:duration];
}

- (void)checkStallWatchdogWithIsPlaying:(BOOL)isPlaying currentTime:(double)currentTime
{
  if (!isPlaying) {
    _stalledSinceMs = 0;
    _lastProgressCurrentTime = -1;
    _hasReportedStall = NO;
    return;
  }
  if (currentTime != _lastProgressCurrentTime) {
    _lastProgressCurrentTime = currentTime;
    _stalledSinceMs = 0;
    if (_hasReportedStall) {
      // We told JS "buffering" for the stall that was being tracked, and
      // currentTime is advancing again — tell it the stall is over.
      _hasReportedStall = NO;
      [self emitBufferingWithRate:100];
    }
    return;
  }
  if (currentTime <= 0) {
    // isPlaying flips true before the very first frame actually arrives —
    // normal RTSP startup buffering, not a stall. Only arm the watchdog once
    // we've seen real forward progress (see Android's identical guard).
    return;
  }
  NSTimeInterval now = CACurrentMediaTime() * 1000.0;
  if (_stalledSinceMs == 0) {
    _stalledSinceMs = now;
    return;
  }
  if (now - _stalledSinceMs >= kStallThresholdMs) {
    _hasReportedStall = YES;
    [self emitBufferingWithRate:0];
    // Re-arm rather than spamming an event every tick.
    _stalledSinceMs = now;
  }
}

- (void)updateVideoInfo
{
  if (_player == nil) {
    return;
  }
  CGSize size = _player.videoSize;
  double duration = (double)_player.media.length.value.doubleValue;
  int width = (int)size.width;
  int height = (int)size.height;

  NSString *hash = [NSString stringWithFormat:@"duration:%.0f;videoSize:%dx%d;", duration, width, height];
  if (_videoInfoHash != nil && [_videoInfoHash isEqualToString:hash]) {
    return;
  }
  _videoInfoHash = hash;

  if (_eventEmitter == nullptr) {
    return;
  }
  auto emitter = std::dynamic_pointer_cast<const RnLibvlcPlayerViewEventEmitter>(_eventEmitter);
  if (!emitter) {
    return;
  }

  // Never send a degenerate/partial aspectRatio — a "W:0" ratio would corrupt
  // any JS-side layout math that trusts it blindly. Empty string means
  // "unknown", same contract as Android (VLCKit has the same documented
  // dimension-reporting limitation as libvlc-android for at least some RTSP
  // sources — see VLCKit#284 — so consumers should have a fallback for that
  // case, e.g. a snapshot-image placeholder).
  std::string aspectRatio = (width > 0 && height > 0) ? (std::to_string(width) + ":" + std::to_string(height)) : "";

  emitter->onVideoLoad({
      .duration = duration,
      .aspectRatio = aspectRatio,
      .videoSize = {.width = (double)width, .height = (double)height},
  });
}

#pragma mark - Event emission

- (void)emitLoadStart
{
  if (_eventEmitter == nullptr) {
    return;
  }
  auto emitter = std::dynamic_pointer_cast<const RnLibvlcPlayerViewEventEmitter>(_eventEmitter);
  if (!emitter) {
    return;
  }
  emitter->onVideoLoadStart({.isPlaying = false});
}

- (void)emitProgressWithIsPlaying:(BOOL)isPlaying position:(double)position currentTime:(double)currentTime duration:(double)duration
{
  if (_eventEmitter == nullptr) {
    return;
  }
  auto emitter = std::dynamic_pointer_cast<const RnLibvlcPlayerViewEventEmitter>(_eventEmitter);
  if (!emitter) {
    return;
  }
  emitter->onVideoProgress({
      .isPlaying = (bool)isPlaying,
      .position = position,
      .currentTime = currentTime,
      .duration = duration,
  });
}

- (void)emitBufferingWithRate:(double)rate
{
  if (_player == nil || _eventEmitter == nullptr) {
    return;
  }
  auto emitter = std::dynamic_pointer_cast<const RnLibvlcPlayerViewEventEmitter>(_eventEmitter);
  if (!emitter) {
    return;
  }
  emitter->onVideoBuffering({
      .isPlaying = (bool)_player.isPlaying,
      .position = (double)_player.position,
      .currentTime = (double)_player.time.value.doubleValue,
      .duration = (double)_player.media.length.value.doubleValue,
      .type = std::string("Buffering"),
      .bufferRate = rate,
  });
}

- (void)emitStatusEventNamed:(NSString *)which type:(NSString *)typeStr
{
  if (_player == nil || _eventEmitter == nullptr) {
    return;
  }
  auto emitter = std::dynamic_pointer_cast<const RnLibvlcPlayerViewEventEmitter>(_eventEmitter);
  if (!emitter) {
    return;
  }

  bool isPlaying = _player.isPlaying;
  double position = _player.position;
  double currentTime = (double)_player.time.value.doubleValue;
  double duration = (double)_player.media.length.value.doubleValue;
  std::string type = std::string([typeStr UTF8String]);

  if ([which isEqualToString:@"open"]) {
    emitter->onVideoOpen({.isPlaying = isPlaying, .position = position, .currentTime = currentTime, .duration = duration, .type = type});
  } else if ([which isEqualToString:@"playing"]) {
    emitter->onVideoPlaying({.isPlaying = isPlaying, .position = position, .currentTime = currentTime, .duration = duration, .type = type});
  } else if ([which isEqualToString:@"paused"]) {
    emitter->onVideoPaused({.isPlaying = isPlaying, .position = position, .currentTime = currentTime, .duration = duration, .type = type});
  } else if ([which isEqualToString:@"stopped"]) {
    emitter->onVideoStopped({.isPlaying = isPlaying, .position = position, .currentTime = currentTime, .duration = duration, .type = type});
  } else if ([which isEqualToString:@"end"]) {
    emitter->onVideoEnd({.isPlaying = isPlaying, .position = position, .currentTime = currentTime, .duration = duration, .type = type});
  } else if ([which isEqualToString:@"error"]) {
    emitter->onVideoError({.isPlaying = isPlaying, .position = position, .currentTime = currentTime, .duration = duration, .type = type});
  }
}

#pragma mark - VLCMediaPlayerDelegate

// VLCKit 4.x passes the new state directly (no NSNotification indirection
// like 3.x), and VLCMediaPlayerStateBuffering no longer exists as a case —
// buffering is exclusively reported via -mediaPlayerBufferingChanged: below.
- (void)mediaPlayerStateChanged:(VLCMediaPlayerState)newState
{
  if (_isReleased || _player == nil) {
    return;
  }
  switch (newState) {
    case VLCMediaPlayerStateOpening:
      [self emitStatusEventNamed:@"open" type:@"Opening"];
      break;
    case VLCMediaPlayerStatePlaying:
      [self emitStatusEventNamed:@"playing" type:@"Playing"];
      break;
    case VLCMediaPlayerStatePaused:
      [self emitStatusEventNamed:@"paused" type:@"Paused"];
      break;
    case VLCMediaPlayerStateStopped:
    case VLCMediaPlayerStateStopping:
      // Deliberately does not touch _isPaused/_pausedProp here — same reason
      // as Android: forcing a paused state on a transient RTSP `Stopped`
      // would freeze live streams. `paused` is only ever driven by the prop.
      [self emitStatusEventNamed:@"stopped" type:@"Stopped"];
      break;
    case VLCMediaPlayerStateEnded:
      // The actual "reached the end of the media" signal, mirroring Android's
      // MediaPlayer.Event.EndReached — was never wired up at all before (fell
      // into `default:` below), not a flaky event, simply missing.
      [self emitStatusEventNamed:@"end" type:@"Ended"];
      break;
    case VLCMediaPlayerStateError:
      // Fix vs. the old iOS library: that one only fired onVideoError from
      // VLCCustomDialogRendererProtocol's cert/login dialog callbacks, never
      // from this state directly — meaning most real RTSP/connection errors
      // were invisible to JS. Always fire it here instead, matching
      // Android's MediaPlayer.Event.EncounteredError (unconditional).
      [self emitStatusEventNamed:@"error" type:@"Error"];
      break;
    default:
      break;
  }
}

// Separate from -mediaPlayerStateChanged: in VLCKit 4.x — progress is
// [0.0, 1.0], "always called with 0.0 and 1.0 before a successful playback"
// per VLCKit's own header doc, i.e. a clean start/end pair rather than 3.x's
// buffering-as-a-player-state that flapped the whole state machine in and
// out of Playing on every network hiccup.
- (void)mediaPlayerBufferingChanged:(float)progress
{
  if (_isReleased || _player == nil) {
    return;
  }
  [self emitBufferingWithRate:progress * 100.0];
}

#pragma mark - RCTComponentViewProtocol

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<RnLibvlcPlayerViewComponentDescriptor>();
}

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
  const auto &oldViewProps = *std::static_pointer_cast<const RnLibvlcPlayerViewProps>(_props);
  const auto &newViewProps = *std::static_pointer_cast<const RnLibvlcPlayerViewProps>(props);

  BOOL sourceChanged = NO;
  if (oldViewProps.uri != newViewProps.uri || oldViewProps.isNetwork != newViewProps.isNetwork ||
      oldViewProps.autoplay != newViewProps.autoplay || oldViewProps.initType != newViewProps.initType ||
      oldViewProps.hwDecoderEnabled != newViewProps.hwDecoderEnabled ||
      oldViewProps.hwDecoderForced != newViewProps.hwDecoderForced ||
      oldViewProps.initOptions != newViewProps.initOptions) {
    sourceChanged = YES;
  }

  _uri = RCTNSStringFromString(newViewProps.uri);
  _isNetworkProp = newViewProps.isNetwork;
  _autoplayProp = newViewProps.autoplay;
  _initType = newViewProps.initType;
  _hwDecoderEnabled = newViewProps.hwDecoderEnabled;
  _hwDecoderForced = newViewProps.hwDecoderForced;

  NSMutableArray<NSString *> *opts = [NSMutableArray arrayWithCapacity:newViewProps.initOptions.size()];
  for (const auto &opt : newViewProps.initOptions) {
    [opts addObject:RCTNSStringFromString(opt)];
  }
  _initOptions = opts;

  _pausedProp = newViewProps.paused;
  _autoAspectRatioProp = newViewProps.autoAspectRatio;
  _videoAspectRatioProp = RCTNSStringFromString(newViewProps.videoAspectRatio);
  _progressUpdateIntervalMs = newViewProps.progressUpdateInterval > 0 ? newViewProps.progressUpdateInterval
                                                                       : kDefaultProgressUpdateIntervalMs;

  if (oldViewProps.muted != newViewProps.muted) {
    [self applyMutedModifier:newViewProps.muted];
  }
  if (oldViewProps.volume != newViewProps.volume) {
    [self applyVolumeModifier:newViewProps.volume];
  }
  if (oldViewProps.rate != newViewProps.rate) {
    [self applyRateModifier:newViewProps.rate];
  }
  if (oldViewProps.videoAspectRatio != newViewProps.videoAspectRatio ||
      oldViewProps.autoAspectRatio != newViewProps.autoAspectRatio) {
    [self applyAspectRatioIfNeeded];
  }

  // Fabric's view-recycling pool calls prepareForRecycle (which tears down
  // _player, see below) but does NOT reset _props — so a recycled view's
  // next updateProps: sees oldUri == newUri and sourceChanged stays NO,
  // even though _player is now nil. Without the `_player == nil` check here,
  // the player would never be rebuilt again after the first recycle: video
  // would play briefly, then stay dead forever (confirmed on-device — one
  // successful connection, then a silent permanent stop on next recycle).
  BOOL needsPlayer = _uri.length > 0 && _player == nil;
  if (sourceChanged || needsPlayer) {
    // `autoplay` wins over the initial `paused` value on creation — this
    // lets a consumer mount with `paused={true}` even for live streams,
    // relying on `autoplay={isLive}` alone to start them. `paused` only
    // takes over as the ongoing control once the player exists (see the
    // `else if` below).
    [self rebuildPlayerWithAutoplay:_autoplayProp];
  } else if (oldViewProps.paused != newViewProps.paused) {
    [self applyPausedModifier:newViewProps.paused];
  }

  if (_progressTimer != nil && oldViewProps.progressUpdateInterval != newViewProps.progressUpdateInterval) {
    [self stopProgressTimer];
    [self startProgressTimerIfNeeded];
  }

  [super updateProps:props oldProps:oldProps];
}

@end

Class<RCTComponentViewProtocol> RnLibvlcPlayerViewCls(void)
{
  return RnLibvlcPlayerView.class;
}
