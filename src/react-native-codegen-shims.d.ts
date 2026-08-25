/**
 * react-native's package.json only exposes typed declarations for
 * `react-native/Libraries/...` deep imports under its
 * "react-native-legacy-deep-imports" export condition — and even then, only
 * for paths that actually ship a matching `.d.ts` (CodegenTypes doesn't; only
 * a Flow `.js` source exists). @react-native/codegen's own TS parser, on the
 * other hand, only recognizes the bare `DirectEventHandler`/`Int32`/etc.
 * identifiers when imported from exactly these deep paths (see
 * RnLibvlcPlayerNativeComponent.ts) — the root package's flattened export is
 * a `CodegenTypes` namespace, which the parser's literal name matching
 * doesn't resolve.
 *
 * Turning on that export condition app-wide (via tsconfig `customConditions`)
 * is not an option: it changes core react-native type resolution well beyond
 * these three modules and broke unrelated files (TextInput, ScrollView,
 * Popover refs, ...) when tried. These ambient shims cover only the exact
 * exports this file's spec actually uses, without touching global resolution.
 */
declare module 'react-native/Libraries/Types/CodegenTypes' {
    import type { NativeSyntheticEvent } from 'react-native';

    export type Double = number;
    export type Int32 = number;
    export type Float = number;
    type DefaultTypes = number | boolean | string | ReadonlyArray<string>;
    export type WithDefault<
        Type extends DefaultTypes,
        Value extends Type | string | undefined | null,
    > = Type | undefined | null;
    export type DirectEventHandler<T> = (
        event: NativeSyntheticEvent<T>,
    ) => void | Promise<void>;
    export type BubblingEventHandler<T> = (
        event: NativeSyntheticEvent<T>,
    ) => void | Promise<void>;
}

declare module 'react-native/Libraries/Utilities/codegenNativeComponent' {
    import type { HostComponent } from 'react-native';
    export default function codegenNativeComponent<Props extends object>(
        componentName: string,
        options?: {
            interfaceOnly?: boolean;
            paperComponentName?: string;
            paperComponentNameDeprecated?: string;
            excludedPlatforms?: ReadonlyArray<'iOS' | 'android'>;
        },
    ): HostComponent<Props>;
}

declare module 'react-native/Libraries/Utilities/codegenNativeCommands' {
    export default function codegenNativeCommands<T extends object>(options: {
        supportedCommands: ReadonlyArray<keyof T extends string ? keyof T : never>;
    }): T;
}
