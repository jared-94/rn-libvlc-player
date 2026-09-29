import React from 'react';
import type { NativeSyntheticEvent, StyleProp, ViewStyle } from 'react-native';

import NativeRnLibvlcPlayerView, {
    Commands,
} from './RnLibvlcPlayerNativeComponent';
import type {
    VideoStatusEvent,
    VideoBufferingEvent,
    VideoProgressEvent,
    VideoLoadEvent,
} from './RnLibvlcPlayerNativeComponent';

export type {
    VideoStatusEvent,
    VideoBufferingEvent,
    VideoProgressEvent,
    VideoLoadEvent,
};

export interface VLCPlayerSource {
    uri: string;
    initType?: number;
    hwDecoderEnabled?: boolean | number;
    hwDecoderForced?: boolean | number;
    initOptions?: string[];
}

export interface VLCPlayerProps {
    source: VLCPlayerSource;
    autoplay?: boolean;
    autoAspectRatio?: boolean;
    paused?: boolean;
    muted?: boolean;
    volume?: number;
    rate?: number;
    repeat?: boolean;
    videoAspectRatio?: string;
    progressUpdateInterval?: number;
    style?: StyleProp<ViewStyle>;
    onLoadStart?: () => void;
    onOpen?: (e: VideoStatusEvent) => void;
    onPlaying?: (e: VideoStatusEvent) => void;
    onPaused?: (e: VideoStatusEvent) => void;
    onStopped?: (e: VideoStatusEvent) => void;
    onEnd?: (e: VideoStatusEvent) => void;
    onError?: (e: VideoStatusEvent) => void;
    onBuffering?: (e: VideoBufferingEvent) => void;
    onProgress?: (e: VideoProgressEvent) => void;
    onLoad?: (e: VideoLoadEvent) => void;
}

export interface VLCPlayerHandle {
    seek(position: number): void;
    resume(autoPlay?: boolean): void;
}

// Matches the URI-sniffing behaviour of the old react-native-vlc-media-player
// JS wrapper: only explicit local-asset-style schemes are treated as non-network.
function normalizeUri(uri: string): string {
    if (uri && uri.startsWith('/')) {
        return `file://${uri}`;
    }
    return uri;
}

function resolveIsNetwork(uri: string): boolean {
    if (!uri || uri.startsWith('/')) {
        return false;
    }
    const isAsset = /^(assets-library|file|content|ms-appx|ms-appdata):/.test(uri);
    return !isAsset;
}

type NativeRef = React.ElementRef<typeof NativeRnLibvlcPlayerView>;

export const VLCPlayer = React.forwardRef<VLCPlayerHandle, VLCPlayerProps>(
    (props, ref) => {
        const nativeRef = React.useRef<NativeRef>(null);

        React.useImperativeHandle(
            ref,
            () => ({
                seek(position: number) {
                    if (nativeRef.current) {
                        Commands.seek(nativeRef.current, position);
                    }
                },
                resume(autoPlay: boolean = true) {
                    if (nativeRef.current) {
                        Commands.resume(nativeRef.current, autoPlay);
                    }
                },
            }),
            [],
        );

        const uri = normalizeUri(props.source?.uri || '');

        // --input-repeat replaces the old library's dead native `repeat` prop
        // (its native setter was a no-op) — this is what actually drove repeat.
        const initOptions = React.useMemo(() => {
            const opts = props.source?.initOptions ? [...props.source.initOptions] : [];
            if (props.repeat) {
                opts.push('--input-repeat=1000');
            }
            return opts;
        }, [props.source?.initOptions, props.repeat]);

        return (
            <NativeRnLibvlcPlayerView
                ref={nativeRef}
                style={props.style}
                uri={uri}
                isNetwork={resolveIsNetwork(uri)}
                autoplay={props.autoplay ?? true}
                initType={props.source?.initType ?? 1}
                hwDecoderEnabled={!!props.source?.hwDecoderEnabled}
                hwDecoderForced={!!props.source?.hwDecoderForced}
                initOptions={initOptions}
                autoAspectRatio={!!props.autoAspectRatio}
                videoAspectRatio={props.videoAspectRatio ?? ''}
                paused={!!props.paused}
                muted={!!props.muted}
                volume={props.volume ?? 100}
                rate={props.rate ?? 1.0}
                progressUpdateInterval={props.progressUpdateInterval ?? 250}
                onVideoLoadStart={props.onLoadStart ? () => props.onLoadStart?.() : undefined}
                onVideoOpen={
                    props.onOpen
                        ? (e: NativeSyntheticEvent<VideoStatusEvent>) => props.onOpen?.(e.nativeEvent)
                        : undefined
                }
                onVideoPlaying={
                    props.onPlaying
                        ? (e: NativeSyntheticEvent<VideoStatusEvent>) => props.onPlaying?.(e.nativeEvent)
                        : undefined
                }
                onVideoPaused={
                    props.onPaused
                        ? (e: NativeSyntheticEvent<VideoStatusEvent>) => props.onPaused?.(e.nativeEvent)
                        : undefined
                }
                onVideoStopped={
                    props.onStopped
                        ? (e: NativeSyntheticEvent<VideoStatusEvent>) => props.onStopped?.(e.nativeEvent)
                        : undefined
                }
                onVideoEnd={
                    props.onEnd
                        ? (e: NativeSyntheticEvent<VideoStatusEvent>) => props.onEnd?.(e.nativeEvent)
                        : undefined
                }
                onVideoError={
                    props.onError
                        ? (e: NativeSyntheticEvent<VideoStatusEvent>) => props.onError?.(e.nativeEvent)
                        : undefined
                }
                onVideoBuffering={
                    props.onBuffering
                        ? (e: NativeSyntheticEvent<VideoBufferingEvent>) => props.onBuffering?.(e.nativeEvent)
                        : undefined
                }
                onVideoProgress={
                    props.onProgress
                        ? (e: NativeSyntheticEvent<VideoProgressEvent>) => props.onProgress?.(e.nativeEvent)
                        : undefined
                }
                onVideoLoad={
                    props.onLoad
                        ? (e: NativeSyntheticEvent<VideoLoadEvent>) => props.onLoad?.(e.nativeEvent)
                        : undefined
                }
            />
        );
    },
);

VLCPlayer.displayName = 'VLCPlayer';

export default VLCPlayer;

// Alias kept for callers importing this component under the name matching
// the underlying native view (RnLibvlcPlayerView) rather than the public
// `VLCPlayer` wrapper name.
export { VLCPlayer as LibVlcPlayerView };
