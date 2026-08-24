const r4os = @import("r4os");

const max_file = 262_144;
const wav_chunk_bytes = 8192;
const synth_sample_rate: u32 = 48_000;
const synth_render_max_frames: u16 = 1024;
const selftest_arg = "/SELFTEST";

const WavInfo = struct {
    sample_rate: u32,
    channels: u16,
    bits: u16,
    data_offset: usize,
    data_len: usize,
};

const Midi = struct {
    tempo_micros_per_quarter: u32 = 500_000,
    division: u32 = 480,
    frame_remainder: u64 = 0,
    pacing_remainder: u64 = 0,
    running_status: u8 = 0,
    paused: bool = false,
};

const MidiTrackResult = enum {
    complete,
    quit,
    failed,
};

const App = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    audio: r4os.Audio,
    advanced: r4os.AdvancedAudio,

    fn init(app: *r4os.App) ?App {
        const audio = app.audio() orelse return null;
        return .{ .sys = app.system(), .desk = app.desktop() orelse return null, .audio = audio, .advanced = audio.advanced() };
    }

    fn argsRaw(self: *const App) [*:0]const u8 {
        return self.sys.argsRaw();
    }

    fn print(self: *const App, value: [*:0]const u8) void {
        self.sys.print(value);
    }

    fn write(self: *const App, value: []const u8) void {
        self.sys.write(value);
    }

    fn println(self: *const App, value: []const u8) void {
        self.sys.println(value);
    }

    fn printHexU32(self: *const App, value: u32) void {
        self.sys.printHexU32(value);
    }

    fn fileRead(self: *const App, path: [*:0]const u8, out: []u8) i32 {
        return self.sys.fileRead(path, out);
    }

    fn sleepTicks(self: *const App, duration: u64) void {
        self.sys.sleepTicks(duration);
    }

    fn timerHz(self: *const App) u64 {
        const hz = self.sys.monotonicHz();
        return if (hz == 0) 100 else hz;
    }

    fn readKey(self: *const App) u8 {
        return self.desk.readKey();
    }

    fn audioOpenStream(self: *const App, rate: u32, channels: u16, format: r4os.PcmFormat) ?r4os.AudioStream {
        return switch (self.audio.openStream(rate, channels, format, r4os.app_audio.default_volume, r4os.time_contract.timeoutForever())) {
            .stream => |stream| stream,
            else => null,
        };
    }

    fn audioWrite(_: *const App, stream: *r4os.AudioStream, data: []const u8) usize {
        return switch (stream.write(data, r4os.time_contract.timeoutForever())) {
            .written => |bytes| bytes,
            else => 0,
        };
    }

    fn audioClose(_: *const App, stream: *r4os.AudioStream) bool {
        return switch (stream.close(r4os.time_contract.timeoutForever())) {
            .ok => true,
            else => false,
        };
    }

    fn sidAcquire(self: *const App) i32 {
        return self.advanced.sidAcquire();
    }

    fn sidLoadData(self: *const App, handle: u32, load_addr: u16, data: []const u8) i32 {
        return self.advanced.sidLoadData(handle, load_addr, data);
    }

    fn sidInit(self: *const App, handle: u32, init_addr: u16, song: u16) i32 {
        return self.advanced.sidInit(handle, init_addr, song);
    }

    fn sidPlayFrame(self: *const App, handle: u32, play_addr: u16, frame_hz: u16) i32 {
        return self.advanced.sidPlayFrame(handle, play_addr, frame_hz);
    }

    fn sidStop(self: *const App, handle: u32) i32 {
        return self.advanced.sidStop(handle);
    }

    fn sidRelease(self: *const App, handle: u32) i32 {
        return self.advanced.sidRelease(handle);
    }

    fn sidModelName(self: *const App) [*:0]const u8 {
        return self.advanced.sidModelName();
    }

    fn midiOpenSynth(self: *const App, backend: [*:0]const u8) i32 {
        return self.advanced.midiOpenSynth(backend);
    }

    fn midiSend(self: *const App, handle: u32, channel: u8, status: u8, data1: u8, data2: u8) i32 {
        return self.advanced.midiSend(handle, channel, status, data1, data2);
    }

    fn midiRender(self: *const App, handle: u32, frames: u16) i32 {
        return self.advanced.midiRender(handle, frames);
    }

    fn midiClose(self: *const App, handle: u32) i32 {
        return self.advanced.midiClose(handle);
    }
};

pub fn r4_app_main(app: *r4os.App) i32 {
    const ctx = App.init(app) orelse return r4os.abi.err_no_group;
    var filebuf: [max_file]u8 = undefined;
    var pcm_buffer: [wav_chunk_bytes]u8 = undefined;

    ctx.println("R4Synth 0.1");
    const path = ctx.argsRaw();
    if (hasArg(path, selftest_arg)) return runSelfTest(&ctx);
    if (path[0] == 0) {
        ctx.println("Usage: SYNTH FILE.EXT");
        return 1;
    }

    ctx.println("Loading...");
    const read = ctx.fileRead(path, filebuf[0..]);
    if (read < 44) {
        ctx.println("Read failed.");
        return 2;
    }
    const data = filebuf[0..@as(usize, @intCast(read))];

    if (startsWith(data, "PSID")) return playSid(&ctx, data, true);
    if (startsWith(data, "RSID")) return playSid(&ctx, data, false);
    if (startsWith(data, "MThd")) return playMidi(&ctx, data);
    if (startsWith(data, "RIFF") and data.len >= 12 and eql(data[8..12], "WAVE")) {
        return playWav(&ctx, data, pcm_buffer[0..]);
    }

    ctx.println("Unsupported format. Need PCM WAV mono/stereo 8/16-bit.");
    return 3;
}

fn runSelfTest(ctx: *const App) i32 {
    ctx.println("SYNTH selftest");
    var status: r4os.abi.AudioServiceStatus = .{};
    if (switch (ctx.audio.status(r4os.time_contract.timeoutForever(), &status)) {
        .ok => false,
        else => true,
    }) return synthFail(ctx, "audsvc-status");

    var pcm: [512]u8 = undefined;
    fillSelfTestPcm(pcm[0..]);
    var stream = ctx.audioOpenStream(48_000, 2, .s16le) orelse return synthFail(ctx, "stream-open");
    const written = ctx.audioWrite(&stream, pcm[0..]);
    const closed = ctx.audioClose(&stream);
    if (written != pcm.len or !closed) return synthFail(ctx, "stream-cycle");

    ctx.println("SYNTH selftest: OK");
    return 0;
}

fn playWav(ctx: *const App, data: []const u8, pcm_buffer: []u8) i32 {
    const info = parseWav(data) orelse {
        ctx.println("Unsupported format. Need PCM WAV mono/stereo 8/16-bit.");
        return 3;
    };

    var stream = ctx.audioOpenStream(info.sample_rate, 2, .s16le) orelse {
        ctx.println("Audio stream failed.");
        return 4;
    };

    ctx.println("Playing WAV. P=Pause Q=Quit");
    var paused = false;
    var offset = info.data_offset;
    const end = minUsize(data.len, info.data_offset + info.data_len);
    var prefill: u32 = 2;
    var pacing_remainder: u64 = 0;
    const timer_hz = ctx.timerHz();

    while (offset < end) {
        const key = ctx.readKey();
        if (key == 'q' or key == 'Q') break;
        if (key == 'p' or key == 'P') {
            paused = !paused;
            ctx.println(if (paused) "Paused" else "Playing");
        }
        if (paused) {
            ctx.sleepTicks(1);
            continue;
        }

        const frames = convertWavChunk(info, data[offset..end], pcm_buffer[0..]);
        if (frames.bytes_read == 0 or frames.bytes_written == 0) break;
        _ = ctx.audioWrite(&stream, pcm_buffer[0..frames.bytes_written]);
        offset += frames.bytes_read;

        if (prefill > 0) {
            prefill -= 1;
        } else {
            const wait_ticks = ticksForFrames(frames.frame_count, info.sample_rate, timer_hz, &pacing_remainder);
            if (wait_ticks != 0) ctx.sleepTicks(wait_ticks);
        }
    }

    _ = ctx.audioClose(&stream);
    ctx.println("Done.");
    return 0;
}

const Converted = struct {
    bytes_read: usize,
    bytes_written: usize,
    frame_count: u32,
};

fn convertWavChunk(info: WavInfo, src: []const u8, out: []u8) Converted {
    const src_frame_bytes: usize = (@as(usize, info.bits) / 8) * info.channels;
    if (src_frame_bytes == 0) return .{ .bytes_read = 0, .bytes_written = 0, .frame_count = 0 };

    const max_frames_by_src = src.len / src_frame_bytes;
    const max_frames_by_out = out.len / 4;
    const frame_count = minUsize(max_frames_by_src, max_frames_by_out);

    var frame: usize = 0;
    while (frame < frame_count) : (frame += 1) {
        const src_index = frame * src_frame_bytes;
        const left = readPcmSample(info.bits, src[src_index..]);
        const right = if (info.channels == 2)
            readPcmSample(info.bits, src[src_index + (@as(usize, info.bits) / 8) ..])
        else
            left;
        writeI16(out, frame * 4, left);
        writeI16(out, frame * 4 + 2, right);
    }

    return .{
        .bytes_read = frame_count * src_frame_bytes,
        .bytes_written = frame_count * 4,
        .frame_count = @intCast(frame_count),
    };
}

fn readPcmSample(bits: u16, data: []const u8) i16 {
    if (bits == 8) return (@as(i16, data[0]) - 128) << 8;
    return @bitCast(readLe16(data, 0));
}

fn parseWav(data: []const u8) ?WavInfo {
    var pos: usize = 12;
    var sample_rate: u32 = 0;
    var channels: u16 = 0;
    var bits: u16 = 0;
    var data_offset: usize = 0;
    var data_len: usize = 0;
    var fmt_found = false;
    var data_found = false;

    while (pos + 8 <= data.len) {
        const chunk_id = data[pos .. pos + 4];
        const chunk_size = readLe32(data, pos + 4);
        const body = pos + 8;
        if (body + chunk_size > data.len) return null;

        if (eql(chunk_id, "fmt ")) {
            if (chunk_size < 16) return null;
            if (readLe16(data, body) != 1) return null;
            channels = readLe16(data, body + 2);
            if (channels != 1 and channels != 2) return null;
            sample_rate = readLe32(data, body + 4);
            bits = readLe16(data, body + 14);
            if (bits != 8 and bits != 16) return null;
            fmt_found = true;
        } else if (eql(chunk_id, "data")) {
            data_offset = body;
            data_len = minUsize(@intCast(chunk_size), data.len - body);
            data_found = true;
        }
        if (fmt_found and data_found) {
            return .{
                .sample_rate = sample_rate,
                .channels = channels,
                .bits = bits,
                .data_offset = data_offset,
                .data_len = data_len,
            };
        }
        pos = body + chunk_size + (chunk_size & 1);
    }
    return null;
}

fn playSid(ctx: *const App, data: []const u8, psid: bool) i32 {
    if (data.len < 124) {
        ctx.println("Unsupported format. Need PCM WAV mono/stereo 8/16-bit.");
        return 3;
    }

    const version = readBe16(data, 4);
    const header_data_offset = readBe16(data, 6);
    var load_addr = readBe16(data, 8);
    const init_addr = readBe16(data, 10);
    const play_addr = readBe16(data, 12);
    const songs = readBe16(data, 14);
    const start_song = readBe16(data, 16);
    const speed = readBe32(data, 18);

    ctx.println("SID detected.");
    ctx.println(if (psid) "Format: PSID" else "Format: RSID");
    printHexLine(ctx, "Version: ", version);
    printHexLine(ctx, "Load: ", load_addr);
    printHexLine(ctx, "Init: ", init_addr);
    printHexLine(ctx, "Play: ", play_addr);
    printHexLine(ctx, "Songs: ", songs);
    printHexLine(ctx, "Start: ", start_song);
    printHexLine(ctx, "Speed: ", speed);
    printTextField(ctx, "Title: ", data, 22);
    printTextField(ctx, "Author: ", data, 54);
    printTextField(ctx, "Released: ", data, 86);
    ctx.print("Model: ");
    ctx.print(ctx.sidModelName());
    ctx.write("\r\n");

    var data_offset: usize = header_data_offset;
    if (data_offset >= data.len) {
        ctx.println("SID runtime failed. Run AUDIO.");
        return 7;
    }
    if (load_addr == 0) {
        if (data_offset + 2 > data.len) {
            ctx.println("SID runtime failed. Run AUDIO.");
            return 7;
        }
        load_addr = readLe16(data, data_offset);
        data_offset += 2;
    }

    ctx.println("Starting SID runtime...");
    const handle = ctx.sidAcquire();
    if (handle < 0) {
        ctx.println("SID runtime failed. Run AUDIO.");
        return 7;
    }
    const sid_handle: u32 = @intCast(handle);
    if (ctx.sidLoadData(sid_handle, load_addr, data[data_offset..]) < 0) return sidFailRelease(ctx, sid_handle);
    if (ctx.sidInit(sid_handle, init_addr, start_song) < 0) return sidFailRelease(ctx, sid_handle);

    if (play_addr != 0) {
        ctx.println("Playing SID. P=Pause Q=Quit");
        var paused = false;
        var pacing_remainder: u64 = 0;
        const timer_hz = ctx.timerHz();
        while (true) {
            const key = ctx.readKey();
            if (key == 'q' or key == 'Q') break;
            if (key == 'p' or key == 'P') {
                paused = !paused;
                ctx.println(if (paused) "Paused" else "Playing");
            }
            if (!paused) {
                while (true) {
                    const result = ctx.sidPlayFrame(sid_handle, play_addr, 50);
                    if (result == r4os.abi.service_api_result_busy) {
                        ctx.sleepTicks(1);
                        continue;
                    }
                    if (result < 0) return sidFailRelease(ctx, sid_handle);
                    break;
                }
                const wait_ticks = ticksForFrames(1, 50, timer_hz, &pacing_remainder);
                if (wait_ticks != 0) ctx.sleepTicks(wait_ticks);
            } else {
                ctx.sleepTicks(1);
            }
        }
    }

    const stopped = ctx.sidStop(sid_handle);
    const released = ctx.sidRelease(sid_handle);
    if (stopped < 0 or released < 0) {
        ctx.println("SID runtime failed. Run AUDIO.");
        return 7;
    }
    ctx.println("SID playback stopped. Run AUDIO.");
    return 0;
}

fn sidFailRelease(ctx: *const App, handle: u32) i32 {
    _ = ctx.sidStop(handle);
    _ = ctx.sidRelease(handle);
    ctx.println("SID runtime failed. Run AUDIO.");
    return 7;
}

fn playMidi(ctx: *const App, data: []const u8) i32 {
    if (data.len < 22 or readBe32(data, 4) != 6) {
        ctx.println("Unsupported format. Need PCM WAV mono/stereo 8/16-bit.");
        return 3;
    }

    const format = readBe16(data, 8);
    const tracks = readBe16(data, 10);
    var midi = Midi{ .division = readBe16(data, 12) };
    if (midi.division == 0) midi.division = 480;

    const handle = ctx.midiOpenSynth("");
    if (handle < 0) {
        ctx.println("MIDI backend not available yet.");
        return 6;
    }
    const synth: u32 = @intCast(handle);

    ctx.println("Playing MIDI. P=Pause Q=Quit");
    var pos: usize = 14;
    var track_index: u16 = 0;
    var outcome: MidiTrackResult = .complete;
    while (track_index < tracks and pos + 8 <= data.len) : (track_index += 1) {
        if (!eql(data[pos .. pos + 4], "MTrk")) break;
        const track_len = readBe32(data, pos + 4);
        const track_start = pos + 8;
        const track_end = minUsize(data.len, track_start + @as(usize, @intCast(track_len)));
        outcome = playMidiTrack(ctx, data[track_start..track_end], synth, &midi);
        if (outcome != .complete) break;
        pos = track_end;
        if ((track_len & 1) != 0 and pos < data.len) pos += 1;
        if (format == 0) break;
    }

    const close_result = ctx.midiClose(synth);
    if (outcome == .failed or close_result < 0) {
        ctx.println("MIDI playback failed.");
        return 6;
    }
    ctx.println("Done.");
    return 0;
}

fn playMidiTrack(ctx: *const App, track: []const u8, synth: u32, midi: *Midi) MidiTrackResult {
    var pos: usize = 0;
    var sent: u32 = 0;
    while (pos < track.len and sent < 16_384) {
        const delta = readVlq(track, &pos) orelse break;
        if (waitMidi(ctx, midi, synth, delta) < 0) return .failed;
        if (checkPlaybackKey(ctx, &midi.paused)) return .quit;
        while (midi.paused) {
            if (checkPlaybackKey(ctx, &midi.paused)) return .quit;
            ctx.sleepTicks(1);
        }
        if (pos >= track.len) break;

        var status = track[pos];
        if (status >= 0x80) {
            pos += 1;
            if (status < 0xF0) midi.running_status = status;
        } else {
            if (midi.running_status == 0) break;
            status = midi.running_status;
        }

        if (status == 0xFF) {
            if (pos >= track.len) break;
            const meta = track[pos];
            pos += 1;
            const len = readVlq(track, &pos) orelse break;
            if (pos + len > track.len) break;
            if (meta == 0x2F) return .complete;
            if (meta == 0x51 and len == 3) {
                const micros = (@as(u32, track[pos]) << 16) | (@as(u32, track[pos + 1]) << 8) | track[pos + 2];
                midi.tempo_micros_per_quarter = maxU32(1, micros);
            }
            pos += len;
            continue;
        }
        if (status == 0xF0 or status == 0xF7) {
            const len = readVlq(track, &pos) orelse break;
            pos = minUsize(track.len, pos + @as(usize, @intCast(len)));
            continue;
        }

        const event_type = status & 0xF0;
        const channel = status & 0x0F;
        if (pos >= track.len) break;
        const data1 = track[pos];
        pos += 1;
        const data2 = if (event_type == 0xC0 or event_type == 0xD0) 0 else blk: {
            if (pos >= track.len) break;
            const value = track[pos];
            pos += 1;
            break :blk value;
        };

        if (shouldSendMidi(event_type, data1)) {
            if (ctx.midiSend(synth, channel, event_type, data1, data2) < 0) return .failed;
            sent += 1;
        }
    }
    return .complete;
}

fn shouldSendMidi(event_type: u8, data1: u8) bool {
    return event_type == 0x90 or event_type == 0x80 or event_type == 0xC0 or
        (event_type == 0xB0 and (data1 == 7 or data1 == 10 or data1 == 11 or data1 == 120 or data1 == 121 or data1 == 123));
}

fn waitMidi(ctx: *const App, midi: *Midi, synth: u32, delta: u32) i32 {
    var remaining_frames = midiFramesForDelta(midi, delta);
    const timer_hz = ctx.timerHz();
    while (remaining_frames > 0) {
        const frames: u16 = @intCast(@min(remaining_frames, @as(u64, synth_render_max_frames)));
        while (true) {
            const result = ctx.midiRender(synth, frames);
            if (result == r4os.abi.service_api_result_busy) {
                ctx.sleepTicks(1);
                continue;
            }
            if (result < 0) return result;
            break;
        }
        const wait_ticks = ticksForFrames(frames, synth_sample_rate, timer_hz, &midi.pacing_remainder);
        if (wait_ticks != 0) ctx.sleepTicks(wait_ticks);
        remaining_frames -= @as(u64, frames);
    }
    return 0;
}

fn midiFramesForDelta(midi: *Midi, delta: u32) u64 {
    if (delta == 0 or midi.division == 0) return 0;
    const denominator = @as(u128, midi.division) * 1_000_000;
    const numerator = @as(u128, delta) * midi.tempo_micros_per_quarter * synth_sample_rate + midi.frame_remainder;
    const frames = numerator / denominator;
    midi.frame_remainder = @intCast(numerator % denominator);
    return @intCast(frames);
}

fn checkPlaybackKey(ctx: *const App, paused: *bool) bool {
    const key = ctx.readKey();
    if (key == 'q' or key == 'Q') return true;
    if (key == 'p' or key == 'P') {
        paused.* = !paused.*;
        ctx.println(if (paused.*) "Paused" else "Playing");
    }
    return false;
}

fn readVlq(data: []const u8, pos: *usize) ?u32 {
    var value: u32 = 0;
    var count: u8 = 0;
    while (count < 4) : (count += 1) {
        if (pos.* >= data.len) return null;
        const byte = data[pos.*];
        pos.* += 1;
        value = (value << 7) | (byte & 0x7F);
        if ((byte & 0x80) == 0) return value;
    }
    return value;
}

fn ticksForFrames(frames: u64, sample_rate: u64, timer_hz: u64, remainder: *u64) u64 {
    if (sample_rate == 0) return 1;
    const numerator = frames * timer_hz + remainder.*;
    const ticks = numerator / sample_rate;
    remainder.* = numerator % sample_rate;
    return ticks;
}

fn printTextField(ctx: *const App, label: []const u8, data: []const u8, offset: usize) void {
    var text: [33]u8 = .{0} ** 33;
    var i: usize = 0;
    while (i < 32 and offset + i < data.len and data[offset + i] != 0) : (i += 1) {
        text[i] = data[offset + i];
    }
    ctx.write(label);
    ctx.print(zptr(text[0..]));
    ctx.write("\r\n");
}

fn printHexLine(ctx: *const App, label: []const u8, value: u32) void {
    ctx.write(label);
    ctx.printHexU32(value);
    ctx.write("\r\n");
}

fn fillSelfTestPcm(out: []u8) void {
    var frame: usize = 0;
    while (frame < out.len / 4) : (frame += 1) {
        const sample: i16 = if (((frame / 12) & 1) == 0) 1800 else -1800;
        writeI16(out, frame * 4, sample);
        writeI16(out, frame * 4 + 2, sample);
    }
}

fn synthFail(ctx: *const App, label: []const u8) i32 {
    ctx.write("SYNTH selftest FAILED: ");
    ctx.println(label);
    return 1;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}

fn startsWith(data: []const u8, prefix: []const u8) bool {
    return data.len >= prefix.len and eql(data[0..prefix.len], prefix);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn readLe16(data: []const u8, offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn readLe32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}

fn readBe16(data: []const u8, offset: usize) u16 {
    return (@as(u16, data[offset]) << 8) | data[offset + 1];
}

fn readBe32(data: []const u8, offset: usize) u32 {
    return (@as(u32, data[offset]) << 24) |
        (@as(u32, data[offset + 1]) << 16) |
        (@as(u32, data[offset + 2]) << 8) |
        data[offset + 3];
}

fn writeI16(out: []u8, index: usize, sample: i16) void {
    const bits: u16 = @bitCast(sample);
    out[index] = @intCast(bits & 0xFF);
    out[index + 1] = @intCast(bits >> 8);
}

fn zptr(buffer: []const u8) [*:0]const u8 {
    return @ptrCast(buffer.ptr);
}

fn minUsize(a: usize, b: usize) usize {
    return if (a < b) a else b;
}

fn maxU32(a: u32, b: u32) u32 {
    return if (a > b) a else b;
}
