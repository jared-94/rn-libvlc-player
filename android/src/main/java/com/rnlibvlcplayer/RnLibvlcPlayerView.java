package com.rnlibvlcplayer;

import android.annotation.SuppressLint;
import android.content.Context;
import android.graphics.SurfaceTexture;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Handler;
import android.os.SystemClock;
import android.util.Log;
import android.view.TextureView;
import android.view.View;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.LifecycleEventListener;
import com.facebook.react.bridge.ReactContext;
import com.facebook.react.bridge.ReadableArray;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.uimanager.ThemedReactContext;
import com.facebook.react.uimanager.UIManagerHelper;
import com.facebook.react.uimanager.events.EventDispatcher;

import org.videolan.libvlc.Dialog;
import org.videolan.libvlc.LibVLC;
import org.videolan.libvlc.Media;
import org.videolan.libvlc.MediaPlayer;
import org.videolan.libvlc.interfaces.IVLCVout;

import java.util.ArrayList;
import java.util.List;

/**
 * TextureView-based. A SurfaceView variant was tried to work around libVLC's
 * video-dimension reporting (Media.VideoTrack metadata AND
 * IVLCVout.OnNewVideoLayoutListener both report 0x0 — a documented libVLC
 * limitation, matching the official VLC-Android app's own VideoHelper.java,
 * which hits the same case) — confirmed on-device that SurfaceView made no
 * difference to that (root cause is elsewhere, see updateVideoInfo()), while
 * carrying real downside risk (SurfaceView doesn't participate in normal View
 * transforms — pinch-zoom, rounded corners — the way TextureView does). Not
 * worth the risk for no payoff, so back to TextureView.
 */
@SuppressLint("ViewConstructor")
class RnLibvlcPlayerView extends TextureView implements
        LifecycleEventListener,
        TextureView.SurfaceTextureListener,
        AudioManager.OnAudioFocusChangeListener {

    private static final String TAG = "RnLibvlcPlayerView";

    // "top"-prefixed internal event names codegen derives from the onXxx props
    // declared in RnLibvlcPlayerNativeComponent.ts (see normalizeInputEventName
    // in @react-native/codegen) — these must match exactly for JS to receive them.
    private static final String EVENT_LOAD_START = "topVideoLoadStart";
    private static final String EVENT_ON_OPEN = "topVideoOpen";
    private static final String EVENT_ON_PLAYING = "topVideoPlaying";
    private static final String EVENT_ON_PAUSED = "topVideoPaused";
    private static final String EVENT_ON_STOPPED = "topVideoStopped";
    private static final String EVENT_ON_ERROR = "topVideoError";
    private static final String EVENT_ON_BUFFERING = "topVideoBuffering";
    private static final String EVENT_ON_PROGRESS = "topVideoProgress";
    private static final String EVENT_ON_LOAD = "topVideoLoad";

    private LibVLC libvlc;
    private MediaPlayer mMediaPlayer = null;
    private boolean isSurfaceViewDestory;
    // View/window size in view-pixels, fed by layout/surface-size events —
    // used for vlcOut.setWindowSize(). Not to be confused with
    // mContentVideoWidth/Height below, which is the decoded video's own pixel
    // dimensions.
    private int mVideoWidth = 0;
    private int mVideoHeight = 0;
    // The decoded frame's actual pixel dimensions, from IVLCVout's own layout
    // callback — a more reliable source than Media.VideoTrack container
    // metadata, which has been observed to report 0x0 for at least one
    // real-world RTSP source even once frames are decoding fine. Used as a
    // fallback for the aspectRatio/videoSize reported in onVideoLoad when the
    // track metadata isn't available.
    private int mContentVideoWidth = 0;
    private int mContentVideoHeight = 0;

    private boolean isPaused = true;
    private boolean isHostPaused = false;
    private boolean isReleased = false;
    private int preVolume = 100;

    // Source props: any change marks mSourcePending, and the whole player is
    // torn down + rebuilt exactly once per commit (via applyPendingSourceIfNeeded,
    // called from the ViewManager's onAfterUpdateTransaction) — this replaces the
    // old library's fragile per-prop-setter createPlayer() re-triggering.
    private String mUri;
    private boolean mIsNetwork;
    private boolean mAutoplayProp = true;
    private int mInitType = 1;
    private boolean mHwDecoderEnabled = false;
    private boolean mHwDecoderForced = false;
    private List<String> mInitOptions = new ArrayList<>();
    private boolean mSourcePending = false;

    // Playback-control props: applied directly to the live player, no rebuild.
    private boolean mPausedProp = false;
    private boolean mMuted = false;
    private boolean autoAspectRatio = false;
    private String mVideoAspectRatioProp = "";

    // Default (not 0): the stall watchdog depends on this loop running, and
    // Fabric doesn't reliably resend a constant prop value (progressUpdateInterval
    // is always 250 from JS) to a native view instance that gets torn down and
    // recreated without React seeing a full unmount — observed on-device as this
    // field staying at a Java-default 0 and the progress loop never arming.
    private static final float DEFAULT_PROGRESS_UPDATE_INTERVAL_MS = 250f;
    private float mProgressUpdateInterval = DEFAULT_PROGRESS_UPDATE_INTERVAL_MS;
    private final Handler mProgressUpdateHandler = new Handler();
    private Runnable mProgressUpdateRunnable = null;

    // Stall watchdog: libVLC's own event listener stays completely silent
    // (no Buffering/Error/Stopped) if a live RTSP stream freezes mid-playback
    // instead of cleanly stopping — observed on-device as `currentTime` simply
    // no longer advancing while `isPlaying()` keeps reporting true. A
    // consumer's auto-reload logic typically only reacts to a *new*
    // low-bufferRate event, so without this, a silent stall never recovers.
    // We track how long currentTime has been unchanged and, past
    // STALL_THRESHOLD_MS, synthesize a low-bufferRate Buffering event so that
    // existing recovery logic kicks in — no consumer-side change needed.
    private static final long STALL_THRESHOLD_MS = 2500;
    private long mLastProgressCurrentTime = -1;
    private long mStalledSinceMs = 0;

    private final AudioManager audioManager;

    private String mVideoInfoHash = null;

    RnLibvlcPlayerView(ThemedReactContext context) {
        super(context);
        audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        this.setSurfaceTextureListener(this);
        this.addOnLayoutChangeListener(onLayoutChangeListener);
        context.addLifecycleEventListener(this);
    }

    @Override
    protected void onDetachedFromWindow() {
        super.onDetachedFromWindow();
        stopPlayback();
    }

    // LifecycleEventListener implementation

    @Override
    public void onHostResume() {
        if (isReleased || mMediaPlayer == null) {
            return;
        }
        try {
            if (isSurfaceViewDestory && isHostPaused) {
                IVLCVout vlcOut = mMediaPlayer.getVLCVout();
                if (!vlcOut.areViewsAttached()) {
                    vlcOut.attachViews(onNewVideoLayoutListener);
                    isSurfaceViewDestory = false;
                    isPaused = false;
                    mMediaPlayer.play();
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "Error in onHostResume", e);
        }
    }

    @Override
    public void onHostPause() {
        if (isReleased) {
            return;
        }
        try {
            if (!isPaused && mMediaPlayer != null) {
                if (mMediaPlayer.isPlaying()) {
                    mMediaPlayer.pause();
                }
                isPaused = true;
                isHostPaused = true;
            }
        } catch (IllegalStateException e) {
            Log.w(TAG, "pause() called on invalid MediaPlayer", e);
        } catch (Exception e) {
            Log.e(TAG, "Unexpected error in onHostPause", e);
        }
    }

    @Override
    public void onHostDestroy() {
        stopPlayback();
    }

    @Override
    public void onAudioFocusChange(int focusChange) {
    }

    private void setProgressUpdateRunnable() {
        if (mMediaPlayer != null && mProgressUpdateInterval > 0 && mProgressUpdateRunnable == null) {
            mProgressUpdateRunnable = new Runnable() {
                @Override
                public void run() {
                    if (mMediaPlayer != null && !isPaused) {
                        boolean isPlaying = mMediaPlayer.isPlaying();
                        long currentTime = mMediaPlayer.getTime();
                        float position = mMediaPlayer.getPosition();
                        long totalLength = mMediaPlayer.getLength();
                        checkStallWatchdog(isPlaying, currentTime, position, totalLength);
                        WritableMap map = Arguments.createMap();
                        map.putBoolean("isPlaying", isPlaying);
                        map.putDouble("position", position);
                        map.putDouble("currentTime", currentTime);
                        map.putDouble("duration", totalLength);
                        updateVideoInfo();
                        emitEvent(EVENT_ON_PROGRESS, map);
                    } else {
                        mStalledSinceMs = 0;
                        mLastProgressCurrentTime = -1;
                    }
                    mProgressUpdateHandler.postDelayed(mProgressUpdateRunnable, Math.round(mProgressUpdateInterval));
                }
            };
            mProgressUpdateHandler.postDelayed(mProgressUpdateRunnable, 0);
        }
    }

    /**
     * See STALL_THRESHOLD_MS javadoc above the field: detects a silent
     * playback freeze (isPlaying=true but currentTime not advancing, with no
     * libVLC event to signal it) and synthesizes one low-bufferRate Buffering
     * event so a consumer's existing auto-reload logic has something to react to.
     */
    private void checkStallWatchdog(boolean isPlaying, long currentTime, float position, long totalLength) {
        if (!isPlaying) {
            mStalledSinceMs = 0;
            mLastProgressCurrentTime = -1;
            return;
        }
        if (currentTime != mLastProgressCurrentTime) {
            mLastProgressCurrentTime = currentTime;
            mStalledSinceMs = 0;
            return;
        }
        if (currentTime <= 0) {
            // isPlaying flips true (and MediaPlayer.getTime() sits at 0) before the
            // very first frame actually arrives — normal RTSP startup buffering, not
            // a stall. Only arm the watchdog once we've seen real forward progress.
            return;
        }
        long now = SystemClock.elapsedRealtime();
        if (mStalledSinceMs == 0) {
            mStalledSinceMs = now;
            return;
        }
        if (now - mStalledSinceMs >= STALL_THRESHOLD_MS) {
            Log.w(TAG, "Playback stall detected (currentTime stuck at " + currentTime
                    + "ms with no libVLC event) — synthesizing a Buffering event to trigger recovery");
            WritableMap map = Arguments.createMap();
            map.putBoolean("isPlaying", isPlaying);
            map.putDouble("position", position);
            map.putDouble("currentTime", currentTime);
            map.putDouble("duration", totalLength);
            map.putString("type", "Buffering");
            map.putDouble("bufferRate", 0);
            emitEvent(EVENT_ON_BUFFERING, map);
            // Re-arm rather than spamming an event every tick — if still stuck
            // STALL_THRESHOLD_MS from now, we'll notify again.
            mStalledSinceMs = now;
        }
    }

    /*************
     * Events Listener
     *************/

    /**
     * Shared by both resize signals we get from Android: the View's own layout
     * bounds changing (onLayoutChangeListener, driven by RN/Yoga) and the
     * TextureView's underlying SurfaceTexture buffer size changing
     * (onSurfaceTextureSizeChanged) — these don't always fire together, and a
     * mid-playback resize (e.g. the player's
     * height being recalculated once a real aspect ratio becomes known from
     * onVideoLoad) can otherwise leave VLC rendering into a stale-sized
     * window while the view itself has already resized, making the image
     * invisible without any error/event.
     */
    private void applyWindowSize(int width, int height) {
        if (width <= 0 || height <= 0) {
            return;
        }
        mVideoWidth = width;
        mVideoHeight = height;
        if (mMediaPlayer != null) {
            IVLCVout vlcOut = mMediaPlayer.getVLCVout();
            vlcOut.setWindowSize(mVideoWidth, mVideoHeight);
            if (autoAspectRatio) {
                mMediaPlayer.setAspectRatio(mVideoWidth + ":" + mVideoHeight);
            }
        }
    }

    private final View.OnLayoutChangeListener onLayoutChangeListener = new View.OnLayoutChangeListener() {
        @Override
        public void onLayoutChange(View view, int i, int i1, int i2, int i3, int i4, int i5, int i6, int i7) {
            applyWindowSize(view.getWidth(), view.getHeight());
        }
    };

    private final MediaPlayer.EventListener mPlayerListener = new MediaPlayer.EventListener() {
        @Override
        public void onEvent(MediaPlayer.Event event) {
            boolean isPlaying = mMediaPlayer.isPlaying();
            long currentTime = mMediaPlayer.getTime();
            float position = mMediaPlayer.getPosition();
            long totalLength = mMediaPlayer.getLength();
            WritableMap map = Arguments.createMap();
            map.putBoolean("isPlaying", isPlaying);
            map.putDouble("position", position);
            map.putDouble("currentTime", currentTime);
            map.putDouble("duration", totalLength);

            switch (event.type) {
                case MediaPlayer.Event.Playing:
                    map.putString("type", "Playing");
                    emitEvent(EVENT_ON_PLAYING, map);
                    break;
                case MediaPlayer.Event.Opening:
                    map.putString("type", "Opening");
                    emitEvent(EVENT_ON_OPEN, map);
                    break;
                case MediaPlayer.Event.Paused:
                    map.putString("type", "Paused");
                    emitEvent(EVENT_ON_PAUSED, map);
                    break;
                case MediaPlayer.Event.Buffering:
                    map.putDouble("bufferRate", event.getBuffering());
                    map.putString("type", "Buffering");
                    emitEvent(EVENT_ON_BUFFERING, map);
                    break;
                case MediaPlayer.Event.Stopped:
                    // Deliberately does not touch `isPaused`/`mPausedProp` here:
                    // the old JS wrapper had to patch this to stop forcing a
                    // native `paused=true` on a transient RTSP `Stopped`, which
                    // froze live streams. `paused` is now only ever driven by
                    // the prop, never by this event.
                    map.putString("type", "Stopped");
                    emitEvent(EVENT_ON_STOPPED, map);
                    break;
                case MediaPlayer.Event.EncounteredError:
                    map.putString("type", "Error");
                    emitEvent(EVENT_ON_ERROR, map);
                    break;
                case MediaPlayer.Event.Vout:
                    // Fires when the number of active video outputs changes —
                    // i.e. exactly when the vout pipeline actually becomes
                    // active, which has turned out to be a more reliable
                    // trigger to re-check video dimensions than polling
                    // getCurrentVideoTrack() on a timer (which never saw
                    // non-zero values at all on some real RTSP sources, even
                    // after minutes of healthy playback).
                    updateVideoInfo();
                    break;
                default:
                    break;
            }
        }
    };

    // See createPlayer()'s m.setEventListener(mMediaListener) call for why
    // this exists at all — attaching it (not just what it does here) is what
    // matters.
    private final Media.EventListener mMediaListener = new Media.EventListener() {
        @Override
        public void onEvent(Media.Event event) {
            if (event.type == Media.Event.ParsedChanged && mMediaPlayer != null) {
                updateVideoInfo();
            }
        }
    };

    private final IVLCVout.OnNewVideoLayoutListener onNewVideoLayoutListener = new IVLCVout.OnNewVideoLayoutListener() {
        @Override
        public void onNewVideoLayout(IVLCVout vout, int width, int height, int visibleWidth, int visibleHeight,
                int sarNum, int sarDen) {
            // Some decode paths report the raw buffer size as 0 while the
            // crop-adjusted visible size is valid (MediaCodec pads buffers to
            // macroblock alignment, e.g. a 1920x1088 buffer for a 1920x1080
            // visible frame) — fall back to visibleWidth/visibleHeight when
            // width/height aren't usable.
            int realWidth = width > 0 ? width : visibleWidth;
            int realHeight = height > 0 ? height : visibleHeight;
            if (realWidth <= 0 || realHeight <= 0) {
                return;
            }
            if (realWidth != mContentVideoWidth || realHeight != mContentVideoHeight) {
                mContentVideoWidth = realWidth;
                mContentVideoHeight = realHeight;
                // Re-run so JS gets an onVideoLoad with the real aspect ratio as
                // soon as it's known, even on sources where Media.VideoTrack
                // metadata never reports valid dimensions (see field javadoc).
                if (mMediaPlayer != null) {
                    updateVideoInfo();
                }
            }
        }
    };

    private final IVLCVout.Callback callback = new IVLCVout.Callback() {
        @Override
        public void onSurfacesCreated(IVLCVout ivlcVout) {
            isSurfaceViewDestory = false;
        }

        @Override
        public void onSurfacesDestroyed(IVLCVout ivlcVout) {
            isSurfaceViewDestory = true;
        }
    };

    /*************
     * MediaPlayer
     *************/

    private void stopPlayback() {
        setKeepScreenOn(false);
        audioManager.abandonAudioFocus(this);
        releasePlayer();
    }

    private void createPlayer(boolean autoplayResume, boolean isResume) {
        releasePlayer();
        mLastProgressCurrentTime = -1;
        mStalledSinceMs = 0;
        mContentVideoWidth = 0;
        mContentVideoHeight = 0;
        if (this.getSurfaceTexture() == null || mUri == null || mUri.isEmpty()) {
            return;
        }
        try {
            final ArrayList<String> cOptions = new ArrayList<>(mInitOptions);

            if (mInitType == 1) {
                libvlc = new LibVLC(getContext());
            } else {
                libvlc = new LibVLC(getContext(), cOptions);
            }

            mMediaPlayer = new MediaPlayer(libvlc);
            setMutedModifier(mMuted);
            mMediaPlayer.setEventListener(mPlayerListener);

            Dialog.setCallbacks(libvlc, new Dialog.Callbacks() {
                @Override
                public void onDisplay(Dialog.QuestionDialog dialog) {
                    // No configurable cert/login handling in v1 — reject/dismiss
                    // everything so VLC never blocks waiting on a dialog answer.
                    dialog.postAction(2);
                }

                @Override
                public void onDisplay(Dialog.ErrorMessage dialog) {
                }

                @Override
                public void onDisplay(Dialog.LoginDialog dialog) {
                    dialog.dismiss();
                }

                @Override
                public void onDisplay(Dialog.ProgressDialog dialog) {
                }

                @Override
                public void onCanceled(Dialog dialog) {
                }

                @Override
                public void onProgressUpdate(Dialog.ProgressDialog dialog) {
                }
            });

            IVLCVout vlcOut = mMediaPlayer.getVLCVout();
            if (mVideoWidth > 0 && mVideoHeight > 0) {
                vlcOut.setWindowSize(mVideoWidth, mVideoHeight);
                if (autoAspectRatio) {
                    mMediaPlayer.setAspectRatio(mVideoWidth + ":" + mVideoHeight);
                }
            }

            Media m;
            if (mIsNetwork) {
                m = new Media(libvlc, Uri.parse(mUri));
            } else {
                m = new Media(libvlc, mUri);
            }
            // Attaching a Media-level listener (distinct from mPlayerListener,
            // which is MediaPlayer-level) was present in the original library
            // this is ported from and turned out to matter: without it,
            // Media.VideoTrack.width/height from getCurrentVideoTrack() has
            // been observed to stay 0 forever on some real RTSP sources, even
            // after minutes of healthy playback. Reacting to ParsedChanged by
            // re-running updateVideoInfo() also means JS gets the real
            // aspectRatio as soon as it's known, without waiting for the next
            // progress tick.
            m.setEventListener(mMediaListener);
            m.setHWDecoderEnabled(mHwDecoderEnabled, mHwDecoderForced);

            mVideoInfoHash = null;
            mMediaPlayer.setMedia(m);
            m.release();
            mMediaPlayer.setScale(0);

            if (!vlcOut.areViewsAttached()) {
                vlcOut.addCallback(callback);
                vlcOut.setVideoSurface(this.getSurfaceTexture());
                vlcOut.attachViews(onNewVideoLayoutListener);
            }

            if (!autoAspectRatio && !mVideoAspectRatioProp.isEmpty()) {
                mMediaPlayer.setAspectRatio(mVideoAspectRatioProp);
            }

            if (isResume) {
                if (autoplayResume) {
                    mMediaPlayer.play();
                    isPaused = false;
                }
            } else if (autoplayResume) {
                isPaused = false;
                mMediaPlayer.play();
            } else {
                isPaused = true;
            }

            WritableMap loadStartMap = Arguments.createMap();
            loadStartMap.putBoolean("isPlaying", false);
            emitEvent(EVENT_LOAD_START, loadStartMap);

            setProgressUpdateRunnable();
            isReleased = false;
        } catch (Exception e) {
            Log.e(TAG, "Error creating VLC player", e);
        }
    }

    private void releasePlayer() {
        if (libvlc == null || mMediaPlayer == null) {
            return;
        }

        final MediaPlayer playerToRelease = mMediaPlayer;
        final LibVLC libvlcToRelease = libvlc;

        // Detach the fields synchronously so no other code path (createPlayer,
        // a re-entrant stopPlayback, etc.) can touch these instances once we
        // start tearing them down below.
        mMediaPlayer = null;
        libvlc = null;
        isReleased = true;
        if (mProgressUpdateRunnable != null) {
            mProgressUpdateHandler.removeCallbacks(mProgressUpdateRunnable);
            mProgressUpdateRunnable = null;
        }

        try {
            final IVLCVout vout = playerToRelease.getVLCVout();
            vout.removeCallback(callback);
            vout.detachViews();
        } catch (Exception e) {
            Log.w(TAG, "Error detaching VLC views", e);
        }

        // MediaPlayer.release()/LibVLC.release() can block the calling thread
        // for several seconds: natively this is
        // libvlc_media_player_release -> input_Close -> vlc_join, which waits
        // for VLC's internal input thread to fully tear down (e.g. closing a
        // stalled/reconnecting RTSP socket). releasePlayer() is reached from
        // onDetachedFromWindow(), which Fabric calls synchronously on the main
        // thread while dispatching a mount batch — blocking there produced a
        // reproducible ANR (main thread stuck in vlc_join) reported on the
        // Play Console after switching to this VLC-based player. Do the
        // actual native release on a background thread instead.
        new Thread(() -> {
            try {
                playerToRelease.release();
            } catch (Exception e) {
                Log.w(TAG, "Error releasing MediaPlayer", e);
            }
            try {
                libvlcToRelease.release();
            } catch (Exception e) {
                Log.w(TAG, "Error releasing LibVLC", e);
            }
        }, "VLCPlayerRelease").start();
    }

    /*************
     * Prop setters (called from RnLibvlcPlayerManager)
     *************/

    void setUri(String uri) {
        mUri = uri;
        mSourcePending = true;
    }

    void setIsNetwork(boolean isNetwork) {
        mIsNetwork = isNetwork;
        mSourcePending = true;
    }

    void setAutoplay(boolean autoplay) {
        mAutoplayProp = autoplay;
        mSourcePending = true;
    }

    void setInitType(int initType) {
        mInitType = initType;
        mSourcePending = true;
    }

    void setHwDecoderEnabled(boolean enabled) {
        mHwDecoderEnabled = enabled;
        mSourcePending = true;
    }

    void setHwDecoderForced(boolean forced) {
        mHwDecoderForced = forced;
        mSourcePending = true;
    }

    void setInitOptionsProp(ReadableArray options) {
        List<String> opts = new ArrayList<>();
        if (options != null) {
            for (int i = 0; i < options.size(); i++) {
                opts.add(options.getString(i));
            }
        }
        mInitOptions = opts;
        mSourcePending = true;
    }

    /**
     * Called once per commit from the ViewManager's onAfterUpdateTransaction,
     * after every changed prop setter for that batch has already run.
     */
    void applyPendingSourceIfNeeded() {
        if (!mSourcePending) {
            return;
        }
        mSourcePending = false;
        if (mUri == null || mUri.isEmpty() || getSurfaceTexture() == null) {
            // No URI yet, or the TextureView surface isn't ready yet —
            // onSurfaceTextureAvailable will pick this up once it is.
            return;
        }
        // `autoplay` wins over the initial `paused` value on creation — this
        // lets a consumer mount with `paused={true}` even for live streams,
        // relying on `autoplay={isLive}` alone to start them. `paused` only
        // takes over as the ongoing control once the player exists.
        createPlayer(mAutoplayProp, false);
    }

    void setPausedModifier(boolean paused) {
        mPausedProp = paused;
        if (mMediaPlayer != null) {
            if (paused) {
                isPaused = true;
                mMediaPlayer.pause();
            } else {
                isPaused = false;
                mMediaPlayer.play();
            }
        }
    }

    void setMutedModifier(boolean muted) {
        mMuted = muted;
        if (mMediaPlayer != null) {
            if (muted) {
                this.preVolume = mMediaPlayer.getVolume();
                mMediaPlayer.setVolume(0);
            } else {
                mMediaPlayer.setVolume(this.preVolume);
            }
        }
    }

    void setVolumeModifier(double volume) {
        if (mMediaPlayer != null) {
            mMediaPlayer.setVolume((int) volume);
        }
    }

    void setRateModifier(double rate) {
        if (mMediaPlayer != null) {
            mMediaPlayer.setRate((float) rate);
        }
    }

    void setAutoAspectRatioProp(boolean auto) {
        autoAspectRatio = auto;
    }

    void setVideoAspectRatioProp(String aspectRatio) {
        mVideoAspectRatioProp = aspectRatio == null ? "" : aspectRatio;
        if (!autoAspectRatio && mMediaPlayer != null && !mVideoAspectRatioProp.isEmpty()) {
            mMediaPlayer.setAspectRatio(mVideoAspectRatioProp);
        }
    }

    void setProgressUpdateIntervalProp(int interval) {
        mProgressUpdateInterval = interval;
        if (mMediaPlayer != null && mProgressUpdateRunnable == null) {
            setProgressUpdateRunnable();
        }
    }

    /*************
     * Commands (called from RnLibvlcPlayerManager)
     *************/

    void setPosition(float position) {
        if (mMediaPlayer != null && position >= 0 && position <= 1) {
            mMediaPlayer.setPosition(position);
        }
    }

    void doResume(boolean autoPlay) {
        createPlayer(autoPlay, true);
    }

    void cleanUpResources() {
        removeOnLayoutChangeListener(onLayoutChangeListener);
        stopPlayback();
    }

    @Override
    public void onSurfaceTextureAvailable(SurfaceTexture surface, int width, int height) {
        mVideoWidth = width;
        mVideoHeight = height;
        if (mUri != null && !mUri.isEmpty()) {
            createPlayer(mAutoplayProp, false);
            mSourcePending = false;
        }
    }

    @Override
    public void onSurfaceTextureSizeChanged(SurfaceTexture surface, int width, int height) {
        applyWindowSize(width, height);
    }

    @Override
    public boolean onSurfaceTextureDestroyed(SurfaceTexture surface) {
        return true;
    }

    @Override
    public void onSurfaceTextureUpdated(SurfaceTexture surface) {
    }

    private void updateVideoInfo() {
        // Querying the audio/subtitle track lists here — even though nothing
        // below uses the result — is deliberate: on at least two real RTSP
        // sources, Media.VideoTrack.width/height from getCurrentVideoTrack()
        // stayed 0 forever without this, but the *original* react-native-vlc-
        // media-player's updateVideoInfo() (which this method is ported from)
        // always queried these too. That suggests these JNI calls have a side
        // effect of making libVLC refresh its whole ES (elementary stream)
        // track cache — including the video track's geometry — that a bare
        // getCurrentVideoTrack() call alone doesn't trigger on its own.
        if (mMediaPlayer.getAudioTracksCount() > 0) {
            mMediaPlayer.getAudioTracks();
        }
        if (mMediaPlayer.getSpuTracksCount() > 0) {
            mMediaPlayer.getSpuTracks();
        }

        // Prefer Media.VideoTrack container metadata; fall back to the decoded
        // frame size from IVLCVout's own layout callback (mContentVideoWidth/
        // Height) when the track reports 0 — see that field's javadoc.
        Media.VideoTrack video = mMediaPlayer.getCurrentVideoTrack();
        int width = (video != null && video.width > 0) ? video.width : mContentVideoWidth;
        int height = (video != null && video.height > 0) ? video.height : mContentVideoHeight;

        StringBuilder infoHash = new StringBuilder();
        infoHash.append("duration:").append(mMediaPlayer.getLength()).append(";");
        infoHash.append("videoSize:").append(width).append("x").append(height).append(";");
        String currentHash = infoHash.toString();

        if (mVideoInfoHash == null || !mVideoInfoHash.equals(currentHash)) {
            WritableMap info = Arguments.createMap();
            info.putDouble("duration", mMediaPlayer.getLength());

            WritableMap mapVideoSize = Arguments.createMap();
            mapVideoSize.putInt("width", width);
            mapVideoSize.putInt("height", height);
            info.putString("aspectRatio", (width > 0 && height > 0) ? (width + ":" + height) : "");
            info.putMap("videoSize", mapVideoSize);

            emitEvent(EVENT_ON_LOAD, info);
            mVideoInfoHash = currentHash;
        }
    }

    private void emitEvent(String name, WritableMap payload) {
        ReactContext reactContext = (ReactContext) getContext();
        EventDispatcher dispatcher = UIManagerHelper.getEventDispatcherForReactTag(reactContext, getId());
        if (dispatcher != null) {
            int surfaceId = UIManagerHelper.getSurfaceId(reactContext);
            dispatcher.dispatchEvent(new RnLibvlcPlayerEvent(surfaceId, getId(), name, payload));
        }
    }
}
