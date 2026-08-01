# Audio Capture (Zig)

A small macOS 15+ app showing the complete Zig effects flow: explicit permission requests, microphone enumeration and invalidation, system-only, microphone-only, and combined capture, plus terminal event handling.

```sh
native dev
```

Recordings are atomically published as `/tmp/native-sdk-system.wav`, `/tmp/native-sdk-microphone.wav`, or `/tmp/native-sdk-combined.wav`. The recorder never overwrites an existing file, so remove or move an earlier output before repeating that source.

Starting capture never prompts. Use the permission buttons first and follow any macOS restart instruction reported by the app.
