# Audio Capture (Zig)

A macOS 15+ app demonstrating the reliable pull stream: explicit permission requests, microphone enumeration, system-only/microphone-only/combined capture, coalesced readiness, paired PCM reads, simple real-time peaks, gap counters, stop-and-drain, and discard.

```sh
native dev
```

Starting capture never prompts. Use the permission buttons first and follow any macOS restart instruction reported by the app.

The SDK does not create a file. Each read borrows aligned signed 16-bit little-endian system and microphone bytes during `update`; this example consumes them immediately. An application can instead copy them into its own encoder, transcription pipeline, meter, or network transport.
