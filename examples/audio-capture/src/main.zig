//! macOS 15+ system-audio and microphone capture through Zig effects.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const canvas_label = "capture-canvas";
const window_width: f32 = 680;
const window_height: f32 = 430;

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

const CaptureStatus = enum { idle, starting, recording, stopped, failed, rejected };

pub const Model = struct {
    status: CaptureStatus = .idle,
    reason: native_sdk.EffectAudioCaptureReason = .none,
    duration_ms: u64 = 0,
    bytes_written: u64 = 0,
    output_committed: bool = false,
    microphone_count: u32 = 0,
    microphone_access: native_sdk.EffectAudioCaptureAccessStatus = .not_determined,
    system_access: native_sdk.EffectAudioCaptureAccessStatus = .not_authorized,
    restart_required: bool = false,

    pub fn statusText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{s} · {s} · {d} ms · {d} bytes · committed={any}", .{
            @tagName(model.status),
            @tagName(model.reason),
            model.duration_ms,
            model.bytes_written,
            model.output_committed,
        }) catch "audio capture";
    }

    pub fn accessText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "microphone={s} · system={s} · restart required={any}", .{
            @tagName(model.microphone_access),
            @tagName(model.system_access),
            model.restart_required,
        }) catch "access status unavailable";
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
    capture: native_sdk.EffectAudioCapture,
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
        .stop => fx.stopAudioCapture(),
        .capture => |event| {
            model.status = switch (event.state) {
                .started => .recording,
                .stopped => .stopped,
                .failed => .failed,
                .rejected => .rejected,
            };
            model.reason = event.reason;
            model.duration_ms = event.duration_ms;
            model.bytes_written = event.bytes_written;
            model.output_committed = event.output_committed;
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
    model.status = .starting;
    model.reason = .none;
    model.duration_ms = 0;
    model.bytes_written = 0;
    model.output_committed = false;
    fx.startAudioCapture(.{
        .key = 10,
        .path = switch (source) {
            .system => "/tmp/native-sdk-system.wav",
            .microphone => "/tmp/native-sdk-microphone.wav",
            .combined => "/tmp/native-sdk-combined.wav",
        },
        .system_audio = source != .microphone,
        .microphone = if (source == .system) .none else .default,
        .on_event = Effects.audioCaptureMsg(.capture),
    });
}

pub const CaptureUi = canvas.Ui(Msg);

pub fn view(ui: *CaptureUi, model: *const Model) CaptureUi.Node {
    return ui.column(.{ .padding = 20, .gap = 14, .style_tokens = .{ .background = .background } }, .{
        ui.text(.{ .size = .lg }, "Audio capture"),
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "macOS 15+ · signed 16-bit PCM WAV · one active capture"),
        ui.row(.{ .gap = 8 }, .{
            ui.button(.{ .on_press = .request_microphone }, "Request microphone"),
            ui.button(.{ .on_press = .request_system_audio }, "Request system audio"),
            ui.button(.{ .on_press = .list_microphones }, "List microphones"),
        }),
        ui.text(.{}, model.accessText(ui.arena)),
        ui.text(.{}, ui.fmt("{d} connected microphone(s)", .{model.microphone_count})),
        ui.separator(.{}),
        ui.row(.{ .gap = 8 }, .{
            ui.button(.{ .variant = .primary, .on_press = .start_combined }, "System + default mic"),
            ui.button(.{ .on_press = .start_system }, "System only"),
            ui.button(.{ .on_press = .start_microphone }, "Mic only"),
            ui.button(.{ .variant = .destructive, .on_press = .stop }, "Stop"),
        }),
        ui.panel(.{ .padding = 14, .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.text(.{}, model.statusText(ui.arena)),
        }),
        ui.spacer(1),
        ui.statusBar(.{}, "Outputs are written under /tmp; existing files are never overwritten."),
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
