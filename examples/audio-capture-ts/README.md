# Audio Capture (TypeScript)

The TypeScript counterpart to `examples/audio-capture`. It demonstrates fixed lifecycle/read/device/access Msg records, `Sub.microphoneDevicesChanged`, coalesced readiness, paired PCM reads, stop-and-drain, and discard.

```sh
native dev
```

The SDK does not create a file. `systemPcm` and `microphonePcm` are borrowed signed 16-bit little-endian bytes covering the same frame interval; this example consumes their lengths and gap counters during `update`.
