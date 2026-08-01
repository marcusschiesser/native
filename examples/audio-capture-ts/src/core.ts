import { Cmd, Sub, asciiBytes, type Cmd as Command, type Sub as Subscription } from "@native-sdk/core";

export type CaptureState = "started" | "stopped" | "failed" | "rejected";
export type CaptureReason =
  | "none" | "invalid_options" | "permission_missing" | "permission_required"
  | "already_recording" | "device_not_found" | "device_disconnected"
  | "output_exists" | "io_failed" | "capture_failed" | "no_audio" | "unsupported";
export type AccessStatus = "authorized" | "not_authorized" | "not_determined" | "denied" | "restricted" | "unavailable";
export type AccessSource = "system_audio" | "microphone";
export type DeviceState = "device" | "completed" | "failed" | "rejected";

export interface Model {
  readonly captureState: CaptureState;
  readonly captureReason: CaptureReason;
  readonly durationMs: number;
  readonly bytesWritten: number;
  readonly outputCommitted: boolean;
  readonly deviceCount: number;
  readonly microphoneAccess: AccessStatus;
  readonly systemAccess: AccessStatus;
  readonly restartRequired: boolean;
}

export type Msg =
  | { readonly kind: "start_capture" }
  | { readonly kind: "stop_capture" }
  | { readonly kind: "list_microphones" }
  | { readonly kind: "request_microphone" }
  | { readonly kind: "request_system_audio" }
  | { readonly kind: "microphones_changed" }
  | { readonly kind: "capture_event"; readonly key: string; readonly state: CaptureState; readonly reason: CaptureReason; readonly durationMs: number; readonly bytesWritten: number; readonly outputCommitted: boolean }
  | { readonly kind: "microphone_device"; readonly key: string; readonly state: DeviceState; readonly id: Uint8Array; readonly name: Uint8Array; readonly isDefault: boolean; readonly index: number; readonly total: number }
  | { readonly kind: "capture_access"; readonly key: string; readonly source: AccessSource; readonly status: AccessStatus; readonly restartRequired: boolean };

export const viewUnbound = ["microphones_changed", "capture_event", "microphone_device", "capture_access", "outputCommitted", "restartRequired"] as const;

export function initialModel(): Model {
  return {
    captureState: "stopped",
    captureReason: "none",
    durationMs: 0,
    bytesWritten: 0,
    outputCommitted: false,
    deviceCount: 0,
    microphoneAccess: "not_determined",
    systemAccess: "not_authorized",
    restartRequired: false,
  };
}

export function update(model: Model, msg: Msg): [Model, Command<Msg>] {
  switch (msg.kind) {
    case "start_capture":
      return [
        { ...model, captureReason: "none", durationMs: 0, bytesWritten: 0, outputCommitted: false },
        Cmd.audioCaptureStart("meeting", {
          path: asciiBytes("/tmp/native-sdk-combined-ts.wav"),
          systemAudio: true,
          microphone: "default",
          sampleRate: 48000,
          channels: 2,
          excludeCurrentProcessAudio: true,
        }, { event: "capture_event" }),
      ];
    case "stop_capture":
      return [model, Cmd.audioCaptureStop("meeting")];
    case "list_microphones":
    case "microphones_changed":
      return [{ ...model, deviceCount: 0 }, Cmd.microphoneDevices("microphones", { event: "microphone_device" })];
    case "request_microphone":
      return [model, Cmd.audioCaptureAccess("mic-access", "microphone", "request", { event: "capture_access" })];
    case "request_system_audio":
      return [model, Cmd.audioCaptureAccess("system-access", "system_audio", "request", { event: "capture_access" })];
    case "capture_event":
      return [{
        ...model,
        captureState: msg.state,
        captureReason: msg.reason,
        durationMs: msg.durationMs,
        bytesWritten: msg.bytesWritten,
        outputCommitted: msg.outputCommitted,
      }, Cmd.none];
    case "microphone_device":
      if (msg.state === "device") return [{ ...model, deviceCount: model.deviceCount + 1 }, Cmd.none];
      return [model, Cmd.none];
    case "capture_access":
      if (msg.source === "microphone") {
        return [{ ...model, microphoneAccess: msg.status, restartRequired: msg.restartRequired }, Cmd.none];
      }
      return [{ ...model, systemAccess: msg.status, restartRequired: msg.restartRequired }, Cmd.none];
  }
}

export function subscriptions(_model: Model): Subscription<Msg> {
  return Sub.microphoneDevicesChanged("microphones_changed");
}
