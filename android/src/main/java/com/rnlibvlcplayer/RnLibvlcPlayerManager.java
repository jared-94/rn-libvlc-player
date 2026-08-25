package com.rnlibvlcplayer;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.facebook.react.bridge.ReadableArray;
import com.facebook.react.module.annotations.ReactModule;
import com.facebook.react.uimanager.SimpleViewManager;
import com.facebook.react.uimanager.ThemedReactContext;
import com.facebook.react.uimanager.ViewManagerDelegate;
import com.facebook.react.viewmanagers.RnLibvlcPlayerViewManagerDelegate;
import com.facebook.react.viewmanagers.RnLibvlcPlayerViewManagerInterface;

@ReactModule(name = RnLibvlcPlayerManager.REACT_CLASS)
public class RnLibvlcPlayerManager extends SimpleViewManager<RnLibvlcPlayerView>
        implements RnLibvlcPlayerViewManagerInterface<RnLibvlcPlayerView> {

    public static final String REACT_CLASS = "RnLibvlcPlayerView";

    private final RnLibvlcPlayerViewManagerDelegate<RnLibvlcPlayerView, RnLibvlcPlayerManager> mDelegate =
            new RnLibvlcPlayerViewManagerDelegate<>(this);

    @Nullable
    @Override
    protected ViewManagerDelegate<RnLibvlcPlayerView> getDelegate() {
        return mDelegate;
    }

    @NonNull
    @Override
    public String getName() {
        return REACT_CLASS;
    }

    @NonNull
    @Override
    protected RnLibvlcPlayerView createViewInstance(@NonNull ThemedReactContext context) {
        return new RnLibvlcPlayerView(context);
    }

    @Override
    public void onDropViewInstance(@NonNull RnLibvlcPlayerView view) {
        view.cleanUpResources();
        super.onDropViewInstance(view);
    }

    // Fabric batches every changed prop setter into one commit, then calls this
    // once — that's where the source (uri/initType/hwDecoder*/initOptions) is
    // actually applied, instead of rebuilding the player on each individual
    // setter like the old library did.
    @Override
    public void onAfterUpdateTransaction(@NonNull RnLibvlcPlayerView view) {
        super.onAfterUpdateTransaction(view);
        view.applyPendingSourceIfNeeded();
    }

    // --- Props ---

    @Override
    public void setUri(RnLibvlcPlayerView view, @Nullable String value) {
        view.setUri(value == null ? "" : value);
    }

    @Override
    public void setIsNetwork(RnLibvlcPlayerView view, boolean value) {
        view.setIsNetwork(value);
    }

    @Override
    public void setAutoplay(RnLibvlcPlayerView view, boolean value) {
        view.setAutoplay(value);
    }

    @Override
    public void setInitType(RnLibvlcPlayerView view, int value) {
        view.setInitType(value);
    }

    @Override
    public void setHwDecoderEnabled(RnLibvlcPlayerView view, boolean value) {
        view.setHwDecoderEnabled(value);
    }

    @Override
    public void setHwDecoderForced(RnLibvlcPlayerView view, boolean value) {
        view.setHwDecoderForced(value);
    }

    @Override
    public void setInitOptions(RnLibvlcPlayerView view, @Nullable ReadableArray value) {
        view.setInitOptionsProp(value);
    }

    @Override
    public void setPaused(RnLibvlcPlayerView view, boolean value) {
        view.setPausedModifier(value);
    }

    @Override
    public void setMuted(RnLibvlcPlayerView view, boolean value) {
        view.setMutedModifier(value);
    }

    @Override
    public void setVolume(RnLibvlcPlayerView view, double value) {
        view.setVolumeModifier(value);
    }

    @Override
    public void setRate(RnLibvlcPlayerView view, double value) {
        view.setRateModifier(value);
    }

    @Override
    public void setAutoAspectRatio(RnLibvlcPlayerView view, boolean value) {
        view.setAutoAspectRatioProp(value);
    }

    @Override
    public void setVideoAspectRatio(RnLibvlcPlayerView view, @Nullable String value) {
        view.setVideoAspectRatioProp(value);
    }

    @Override
    public void setProgressUpdateInterval(RnLibvlcPlayerView view, int value) {
        view.setProgressUpdateIntervalProp(value);
    }

    // --- Commands ---

    @Override
    public void seek(RnLibvlcPlayerView view, double position) {
        view.setPosition((float) position);
    }

    @Override
    public void resume(RnLibvlcPlayerView view, boolean autoPlay) {
        view.doResume(autoPlay);
    }
}
