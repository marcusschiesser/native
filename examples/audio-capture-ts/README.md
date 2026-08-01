# Audio Capture (TypeScript)

The TypeScript counterpart to `examples/audio-capture`. It demonstrates fixed capture, device, and access Msg records plus `Sub.microphoneDevicesChanged` invalidation.

```sh
native dev
```

The combined recording is atomically published as `/tmp/native-sdk-combined-ts.wav`; an existing destination is rejected instead of overwritten.
