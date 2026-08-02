import { Cmd, Sub, type Cmd as Command, type Sub as Subscription } from "@native-sdk/core";

export type CaptureState = "started" | "readable" | "stopped" | "failed" | "rejected";
export type CaptureReason =
  | "none" | "invalid_options" | "permission_missing" | "permission_required"
  | "already_recording" | "device_not_found" | "device_disconnected"
  | "capture_failed" | "no_audio" | "consumer_too_slow" | "discarded" | "unsupported";
export type ReadState = "chunk" | "empty" | "ended" | "rejected";
export type ReadReason = "none" | "invalid_options" | "not_recording" | "read_in_progress";
export type AccessStatus = "authorized" | "not_authorized" | "not_determined" | "denied" | "restricted" | "unavailable";
export type AccessSource = "system_audio" | "microphone";
export type DeviceState = "device" | "completed" | "failed" | "rejected";

export interface Model {
  readonly captureState: CaptureState;
  readonly captureReason: CaptureReason;
  readonly sampleRate: number;
  readonly channels: number;
  readonly availableFrames: number;
  readonly capacityFrames: number;
  readonly framesConsumed: number;
  readonly systemGapFrames: number;
  readonly microphoneGapFrames: number;
  readonly lastSystemBytes: number;
  readonly lastMicrophoneBytes: number;
  readonly readPending: boolean;
  readonly terminalSeen: boolean;
  readonly deviceCount: number;
  readonly microphoneAccess: AccessStatus;
  readonly systemAccess: AccessStatus;
  readonly restartRequired: boolean;
}

export type Msg =
  | { readonly kind: "start_capture" }
  | { readonly kind: "stop_capture" }
  | { readonly kind: "discard_capture" }
  | { readonly kind: "list_microphones" }
  | { readonly kind: "request_microphone" }
  | { readonly kind: "request_system_audio" }
  | { readonly kind: "microphones_changed" }
  | { readonly kind: "capture_event"; readonly key: string; readonly state: CaptureState; readonly reason: CaptureReason; readonly sampleRate: number; readonly channels: number; readonly availableFrames: number; readonly capacityFrames: number; readonly framesProduced: number }
  | { readonly kind: "capture_read"; readonly key: string; readonly state: ReadState; readonly reason: ReadReason; readonly sequence: number; readonly frameOffset: number; readonly frames: number; readonly systemPcm: Uint8Array; readonly microphonePcm: Uint8Array; readonly systemGapFrames: number; readonly microphoneGapFrames: number; readonly remainingFrames: number; readonly endOfStream: boolean }
  | { readonly kind: "microphone_device"; readonly key: string; readonly state: DeviceState; readonly id: Uint8Array; readonly name: Uint8Array; readonly isDefault: boolean; readonly index: number; readonly total: number }
  | { readonly kind: "capture_access"; readonly key: string; readonly source: AccessSource; readonly status: AccessStatus; readonly restartRequired: boolean };

export const viewUnbound = ["microphones_changed", "capture_event", "capture_read", "microphone_device", "capture_access", "readPending", "terminalSeen", "restartRequired"] as const;

export function initialModel(): Model {
  return {
    captureState: "stopped", captureReason: "none", sampleRate: 0, channels: 0,
    availableFrames: 0, capacityFrames: 0, framesConsumed: 0,
    systemGapFrames: 0, microphoneGapFrames: 0,
    lastSystemBytes: 0, lastMicrophoneBytes: 0,
    readPending: false, terminalSeen: false, deviceCount: 0,
    microphoneAccess: "not_determined", systemAccess: "not_authorized", restartRequired: false,
  };
}

export function update(model: Model, msg: Msg): [Model, Command<Msg>] {
  switch (msg.kind) {
    case "start_capture":
      return [{
        ...model, captureState: "started", captureReason: "none", sampleRate: 0, channels: 0,
        availableFrames: 0, capacityFrames: 0, framesConsumed: 0,
        systemGapFrames: 0, microphoneGapFrames: 0,
        lastSystemBytes: 0, lastMicrophoneBytes: 0, readPending: false, terminalSeen: false,
      }, Cmd.audioCaptureStart("meeting", {
        systemAudio: true,
        microphone: "default",
        sampleRate: 48000,
        channels: 2,
        excludeCurrentProcessAudio: true,
        bufferDurationMs: 5000,
      }, { event: "capture_event" })];
    case "stop_capture":
      return [model, Cmd.audioCaptureStop("meeting")];
    case "discard_capture":
      return [{ ...model, captureState: "stopped", terminalSeen: true, readPending: false }, Cmd.audioCaptureDiscard("meeting")];
    case "list_microphones":
    case "microphones_changed":
      return [{ ...model, deviceCount: 0 }, Cmd.microphoneDevices("microphones", { event: "microphone_device" })];
    case "request_microphone":
      return [model, Cmd.audioCaptureAccess("mic-access", "microphone", "request", { event: "capture_access" })];
    case "request_system_audio":
      return [model, Cmd.audioCaptureAccess("system-access", "system_audio", "request", { event: "capture_access" })];
    case "capture_event": {
      const terminal = msg.state === "stopped" || msg.state === "failed";
      const next: Model = {
        ...model, captureState: msg.state, captureReason: msg.reason,
        sampleRate: msg.sampleRate, channels: msg.channels,
        availableFrames: msg.availableFrames, capacityFrames: msg.capacityFrames,
        terminalSeen: model.terminalSeen || terminal || msg.state === "rejected",
      };
      if ((msg.state === "readable" || terminal) && !next.readPending) {
        return [{ ...next, readPending: true }, Cmd.audioCaptureRead("meeting", 4800, { event: "capture_read" })];
      }
      return [next, Cmd.none];
    }
    case "capture_read": {
      const next: Model = {
        ...model, readPending: false, availableFrames: msg.remainingFrames,
        framesConsumed: model.framesConsumed + msg.frames,
        systemGapFrames: model.systemGapFrames + msg.systemGapFrames,
        microphoneGapFrames: model.microphoneGapFrames + msg.microphoneGapFrames,
        lastSystemBytes: msg.systemPcm.length,
        lastMicrophoneBytes: msg.microphonePcm.length,
      };
      if (!msg.endOfStream && (msg.remainingFrames > 0 || next.terminalSeen)) {
        return [{ ...next, readPending: true }, Cmd.audioCaptureRead("meeting", 4800, { event: "capture_read" })];
      }
      return [next, Cmd.none];
    }
    case "microphone_device":
      if (msg.state === "device") return [{ ...model, deviceCount: model.deviceCount + 1 }, Cmd.none];
      return [model, Cmd.none];
    case "capture_access":
      if (msg.source === "microphone") return [{ ...model, microphoneAccess: msg.status, restartRequired: msg.restartRequired }, Cmd.none];
      return [{ ...model, systemAccess: msg.status, restartRequired: msg.restartRequired }, Cmd.none];
  }
}

export function subscriptions(_model: Model): Subscription<Msg> {
  return Sub.microphoneDevicesChanged("microphones_changed");
}
