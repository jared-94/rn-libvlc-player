/// <reference path="./react-native-codegen-shims.d.ts" />
import type * as React from 'react';
import type { HostComponent, ViewProps } from 'react-native';
import type {
    Double,
    Int32,
    WithDefault,
    DirectEventHandler,
} from 'react-native/Libraries/Types/CodegenTypes';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';
import codegenNativeCommands from 'react-native/Libraries/Utilities/codegenNativeCommands';

export type VideoStatusEvent = Readonly<{
    isPlaying: boolean;
    position: Double;
    currentTime: Double;
    duration: Double;
    type: string;
}>;

export type VideoBufferingEvent = Readonly<{
    isPlaying: boolean;
    position: Double;
    currentTime: Double;
    duration: Double;
    type: string;
    bufferRate: Double;
}>;

export type VideoProgressEvent = Readonly<{
    isPlaying: boolean;
    position: Double;
    currentTime: Double;
    duration: Double;
}>;

export type VideoLoadEvent = Readonly<{
    duration: Double;
    aspectRatio: string;
    videoSize: Readonly<{
        width: Double;
        height: Double;
    }>;
}>;

export interface NativeProps extends ViewProps {
    // Source (grouped: any change here tears down and recreates the player once,
    // batched via the ViewManager's onAfterUpdateTransaction hook)
    uri?: WithDefault<string, ''>;
    isNetwork?: WithDefault<boolean, false>;
    autoplay?: WithDefault<boolean, true>;
    initType?: WithDefault<Int32, 1>;
    hwDecoderEnabled?: WithDefault<boolean, false>;
    hwDecoderForced?: WithDefault<boolean, false>;
    initOptions?: ReadonlyArray<string>;

    // Playback control (applied to the live player, no recreation)
    paused?: WithDefault<boolean, false>;
    muted?: WithDefault<boolean, false>;
    volume?: WithDefault<Double, 100>;
    rate?: WithDefault<Double, 1.0>;
    autoAspectRatio?: WithDefault<boolean, false>;
    videoAspectRatio?: WithDefault<string, ''>;
    progressUpdateInterval?: WithDefault<Int32, 250>;

    // Events
    // (codegen's TS parser can't resolve an empty `Readonly<{}>` payload —
    // needs at least one real field)
    onVideoLoadStart?: DirectEventHandler<Readonly<{ isPlaying: boolean }>>;
    onVideoOpen?: DirectEventHandler<VideoStatusEvent>;
    onVideoPlaying?: DirectEventHandler<VideoStatusEvent>;
    onVideoPaused?: DirectEventHandler<VideoStatusEvent>;
    onVideoStopped?: DirectEventHandler<VideoStatusEvent>;
    // Fires once when playback reaches the natural end of the media (libVLC's
    // MediaPlayer.Event.EndReached / VLCKit's VLCMediaPlayerStateEnded) — distinct
    // from onVideoStopped, which also fires for other transitions (e.g. a live
    // stream disconnecting) and is deliberately NOT treated as "playback finished"
    // elsewhere in this library (see the Android/iOS Stopped-case comments).
    onVideoEnd?: DirectEventHandler<VideoStatusEvent>;
    onVideoError?: DirectEventHandler<VideoStatusEvent>;
    onVideoBuffering?: DirectEventHandler<VideoBufferingEvent>;
    onVideoProgress?: DirectEventHandler<VideoProgressEvent>;
    onVideoLoad?: DirectEventHandler<VideoLoadEvent>;
}

type NativeType = HostComponent<NativeProps>;

interface NativeCommands {
    seek: (viewRef: React.ElementRef<NativeType>, position: Double) => void;
    resume: (viewRef: React.ElementRef<NativeType>, autoPlay: boolean) => void;
}

export const Commands: NativeCommands = codegenNativeCommands<NativeCommands>({
    supportedCommands: ['seek', 'resume'],
});

export default codegenNativeComponent<NativeProps>(
    'RnLibvlcPlayerView',
) as NativeType;
