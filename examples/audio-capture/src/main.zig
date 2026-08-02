//! macOS 15+ reliable paired system-audio and microphone capture.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const canvas_label = "capture-canvas";
const window_width: f32 = 720;
const window_height: f32 = 460;

const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Audio capture canvas", .accessibility_label = "Audio capture", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Audio Capture",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

const CaptureStatus = enum { idle, starting, recording, draining, stopped, failed, rejected };

pub const Model = struct {
    status: CaptureStatus = .idle,
    reason: native_sdk.EffectAudioCaptureReason = .none,
    sample_rate_hz: u32 = 0,
    channel_count: u8 = 0,
    available_frames: u32 = 0,
    capacity_frames: u32 = 0,
    frames_consumed: u64 = 0,
    system_gap_frames: u64 = 0,
    microphone_gap_frames: u64 = 0,
    system_peak: u16 = 0,
    microphone_peak: u16 = 0,
    read_pending: bool = false,
    terminal_seen: bool = false,
    microphone_count: u32 = 0,
    microphone_access: native_sdk.EffectAudioCaptureAccessStatus = .not_determined,
    system_access: native_sdk.EffectAudioCaptureAccessStatus = .not_authorized,
    restart_required: bool = false,

    pub fn statusText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{s} · {s} · {d}/{d} buffered frames · {d} consumed", .{
            @tagName(model.status), @tagName(model.reason), model.available_frames,
            model.capacity_frames,  model.frames_consumed,
        }) catch "audio capture";
    }

    pub fn levelsText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "system peak={d} · mic peak={d} · inserted gaps {d}/{d}", .{
            model.system_peak,       model.microphone_peak,
            model.system_gap_frames, model.microphone_gap_frames,
        }) catch "levels unavailable";
    }
};

pub const Msg = union(enum) {
    request_microphone,
    request_system_audio,
    list_microphones,
    start_system,
    start_microphone,
    start_combined,
    stop,
    discard,
    capture: native_sdk.EffectAudioCapture,
    capture_read: native_sdk.EffectAudioCaptureRead,
    microphone: native_sdk.EffectMicrophoneDevice,
    access: native_sdk.EffectAudioCaptureAccess,
    microphones_changed,
};

const CaptureApp = native_sdk.UiApp(Model, Msg);
pub const Effects = CaptureApp.Effects;

pub fn boot(_: *Model, fx: *Effects) void {
    fx.observeMicrophoneDevices(Effects.microphoneDevicesChangedMsg(.microphones_changed));
    fx.audioCaptureAccess(.{ .key = 1, .source = .microphone, .on_event = Effects.audioCaptureAccessMsg(.access) });
    fx.audioCaptureAccess(.{ .key = 2, .source = .system_audio, .on_event = Effects.audioCaptureAccessMsg(.access) });
}

fn requestRead(model: *Model, fx: *Effects) void {
    if (model.read_pending) return;
    model.read_pending = true;
    fx.readAudioCapture(.{ .key = 10, .max_frames = 4_800, .on_read = Effects.audioCaptureReadMsg(.capture_read) });
}

fn peak(pcm: []const u8) u16 {
    var result: u16 = 0;
    var index: usize = 0;
    while (index + 1 < pcm.len) : (index += 2) {
        const sample = std.mem.readInt(i16, pcm[index..][0..2], .little);
        const magnitude: u16 = if (sample == std.math.minInt(i16)) 32_768 else @intCast(@abs(sample));
        result = @max(result, magnitude);
    }
    return result;
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .request_microphone => fx.audioCaptureAccess(.{ .key = 3, .source = .microphone, .action = .request, .on_event = Effects.audioCaptureAccessMsg(.access) }),
        .request_system_audio => fx.audioCaptureAccess(.{ .key = 4, .source = .system_audio, .action = .request, .on_event = Effects.audioCaptureAccessMsg(.access) }),
        .list_microphones, .microphones_changed => {
            model.microphone_count = 0;
            fx.listMicrophoneDevices(.{ .key = 5, .on_event = Effects.microphoneDeviceMsg(.microphone) });
        },
        .start_system => start(model, fx, .system),
        .start_microphone => start(model, fx, .microphone),
        .start_combined => start(model, fx, .combined),
        .stop => {
            model.status = .draining;
            fx.stopAudioCapture();
        },
        .discard => {
            model.read_pending = false;
            model.terminal_seen = true;
            model.status = .stopped;
            fx.discardAudioCapture();
        },
        .capture => |event| {
            model.reason = event.reason;
            model.sample_rate_hz = event.sample_rate_hz;
            model.channel_count = event.channel_count;
            model.available_frames = event.available_frames;
            model.capacity_frames = event.capacity_frames;
            switch (event.state) {
                .started => model.status = .recording,
                .readable => requestRead(model, fx),
                .stopped => {
                    model.status = .draining;
                    model.terminal_seen = true;
                    requestRead(model, fx);
                },
                .failed => {
                    model.status = .failed;
                    model.terminal_seen = true;
                    requestRead(model, fx);
                },
                .rejected => {
                    model.status = .rejected;
                    model.terminal_seen = true;
                },
            }
        },
        .capture_read => |event| {
            model.read_pending = false;
            model.available_frames = event.remaining_frames;
            if (event.state == .chunk) {
                model.frames_consumed += event.frames;
                model.system_gap_frames += event.system_gap_frames;
                model.microphone_gap_frames += event.microphone_gap_frames;
                model.system_peak = peak(event.system_pcm);
                model.microphone_peak = peak(event.microphone_pcm);
            }
            if (event.end_of_stream or event.state == .ended) {
                if (model.status == .draining) model.status = .stopped;
            } else if (event.remaining_frames > 0 or model.terminal_seen) {
                requestRead(model, fx);
            }
        },
        .microphone => |event| if (event.state == .device) {
            model.microphone_count += 1;
        },
        .access => |event| {
            switch (event.source) {
                .microphone => model.microphone_access = event.status,
                .system_audio => model.system_access = event.status,
            }
            model.restart_required = event.restart_required;
        },
    }
}

const Source = enum { system, microphone, combined };

fn start(model: *Model, fx: *Effects, source: Source) void {
    model.* = .{
        .status = .starting,
        .microphone_count = model.microphone_count,
        .microphone_access = model.microphone_access,
        .system_access = model.system_access,
        .restart_required = model.restart_required,
    };
    fx.startAudioCapture(.{
        .key = 10,
        .system_audio = source != .microphone,
        .microphone = if (source == .system) .none else .default,
        .buffer_duration_ms = 5_000,
        .on_event = Effects.audioCaptureMsg(.capture),
    });
}

pub const CaptureUi = canvas.Ui(Msg);

pub fn view(ui: *CaptureUi, model: *const Model) CaptureUi.Node {
    return ui.column(.{ .padding = 20, .gap = 14, .style_tokens = .{ .background = .background } }, .{
        ui.text(.{ .size = .lg }, "Reliable audio stream"),
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "macOS 15+ · aligned s16le system/microphone chunks · 5 second buffer"),
        ui.row(.{ .gap = 8 }, .{
            ui.button(.{ .on_press = .request_microphone }, "Request microphone"),
            ui.button(.{ .on_press = .request_system_audio }, "Request system audio"),
            ui.button(.{ .on_press = .list_microphones }, "List microphones"),
        }),
        ui.text(.{}, ui.fmt("microphone={s} · system={s} · restart={any}", .{ @tagName(model.microphone_access), @tagName(model.system_access), model.restart_required })),
        ui.text(.{}, ui.fmt("{d} connected microphone(s)", .{model.microphone_count})),
        ui.separator(.{}),
        ui.row(.{ .gap = 8 }, .{
            ui.button(.{ .variant = .primary, .on_press = .start_combined }, "System + default mic"),
            ui.button(.{ .on_press = .start_system }, "System only"),
            ui.button(.{ .on_press = .start_microphone }, "Mic only"),
            ui.button(.{ .variant = .destructive, .on_press = .stop }, "Stop + drain"),
            ui.button(.{ .on_press = .discard }, "Discard"),
        }),
        ui.panel(.{ .padding = 14, .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.text(.{}, model.statusText(ui.arena)),
            ui.text(.{}, model.levelsText(ui.arena)),
        }),
        ui.spacer(1),
        ui.statusBar(.{}, "The app consumes borrowed PCM immediately; no file is created by the SDK."),
    });
}

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(CaptureApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = CaptureApp.init(std.heap.page_allocator, .{}, .{
        .name = "audio-capture",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .init_fx = boot,
        .update_fx = update,
        .view = view,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "audio-capture",
        .window_title = "Native SDK Audio Capture",
        .bundle_id = "dev.native_sdk.audio_capture",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{ .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } } },
    }, init);
}
