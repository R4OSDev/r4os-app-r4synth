const std = @import("std");
const r4os = @import("r4os");
const app = @import("main.zig");
const a = r4os.abi;
const t = std.testing;

// Exercise the real application, WAV conversion, WriteCursor and owned SDK
// transport. Only external time, input/file and service callbacks are modeled.
const Host = struct {
    var now: u64 = 0;
    var hz: u32 = 1000;
    var sleep_available: bool = true;
    var slept: u64 = 0;
    var write_cost: u64 = 0;
    var key_cost: u64 = 0;
    var file_cost: u64 = 0;
    var fragmented: bool = false;
    var initial_busy: usize = 0;
    var pause: bool = false;
    var quit: bool = false;
    var key_calls: usize = 0;
    var calls: usize = 0;
    var accepted: usize = 0;
    var opens: usize = 0;
    var closes: usize = 0;
    var connections_closed: usize = 0;
    var close_result: i32 = 0;
    var source_rate: u32 = 48_000;
    var first_write: ?u64 = null;
    var largest_source_lead: u64 = 0;
    var resume_tick: ?u64 = null;
    var resume_accepted: usize = 0;
    var resume_largest_source_lead: u64 = 0;
    var file: [200_000]u8 = undefined;
    var file_len: usize = 0;
    var expected: [200_000]u8 = undefined;
    var expected_len: usize = 0;
    var pcm: [200_000]u8 = undefined;

    fn reset() void {
        now = 0;
        hz = 1000;
        sleep_available = true;
        slept = 0;
        write_cost = 0;
        key_cost = 0;
        file_cost = 0;
        fragmented = false;
        initial_busy = 0;
        pause = false;
        quit = false;
        key_calls = 0;
        calls = 0;
        accepted = 0;
        opens = 0;
        closes = 0;
        connections_closed = 0;
        close_result = 0;
        source_rate = 48_000;
        first_write = null;
        largest_source_lead = 0;
        resume_tick = null;
        resume_accepted = 0;
        resume_largest_source_lead = 0;
        file_len = 0;
        expected_len = 0;
    }
    fn wav(rate: u32, channels: u16, bits: u16, frames: usize) void {
        source_rate = rate;
        const source_frame_bytes = channels * (bits / 8);
        const data_len = frames * source_frame_bytes;
        file_len = 44 + data_len;
        expected_len = frames * 4;
        @memset(file[0..44], 0);
        @memcpy(file[0..4], "RIFF");
        std.mem.writeInt(u32, file[4..8], @intCast(file_len - 8), .little);
        @memcpy(file[8..16], "WAVEfmt ");
        std.mem.writeInt(u32, file[16..20], 16, .little);
        std.mem.writeInt(u16, file[20..22], 1, .little);
        std.mem.writeInt(u16, file[22..24], channels, .little);
        std.mem.writeInt(u32, file[24..28], rate, .little);
        std.mem.writeInt(u32, file[28..32], rate * source_frame_bytes, .little);
        std.mem.writeInt(u16, file[32..34], source_frame_bytes, .little);
        std.mem.writeInt(u16, file[34..36], bits, .little);
        @memcpy(file[36..40], "data");
        std.mem.writeInt(u32, file[40..44], @intCast(data_len), .little);
        for (0..frames) |frame| {
            for (0..2) |channel| {
                const source_channel = @min(channel, channels - 1);
                const value: u8 = @truncate(frame * 17 + source_channel * 31 + 3);
                const sample: i16 = (@as(i16, value) - 128) * 256;
                std.mem.writeInt(i16, expected[frame * 4 + channel * 2 ..][0..2], sample, .little);
                if (channel >= channels) continue;
                const offset = 44 + frame * source_frame_bytes + channel * (bits / 8);
                if (bits == 8) file[offset] = value else std.mem.writeInt(i16, file[offset..][0..2], sample, .little);
            }
        }
    }
    fn ticks() callconv(.c) u64 {
        return now;
    }
    fn sleep(count: u64) callconv(.c) void {
        slept += count;
        now += count;
    }
    fn clock(out: *a.MonotonicClockInfo) callconv(.c) i32 {
        out.* = .{ .event_effective_hz = hz };
        return 1;
    }
    fn output(_: [*]const u8, len: u32) callconv(.c) i32 {
        return @intCast(len);
    }
    fn read(_: [*:0]const u8, out: [*]u8, capacity: u32) callconv(.c) i32 {
        if (file_len > capacity) return -1;
        now += file_cost;
        @memcpy(out[0..file_len], file[0..file_len]);
        return @intCast(file_len);
    }
    fn key() callconv(.c) u8 {
        key_calls += 1;
        now += key_cost;
        if (quit and key_calls == 4) return 'q';
        if (pause) {
            if (key_calls == 4) return 'p';
            if (key_calls == 7) {
                resume_tick = now;
                resume_accepted = accepted;
                return 'p';
            }
            if (key_calls == 5) now += 1000;
        }
        return 0;
    }
    fn open(_: [*:0]const u8, out: *a.ServiceInfo) callconv(.c) i32 {
        out.* = .{ .handle = 1 };
        return 0;
    }
    fn disconnect(_: u32) callconv(.c) i32 {
        connections_closed += 1;
        return 0;
    }
    fn call(_: u32, op: u16, bytes: [*]const u8, len: u32, header: *a.ServiceMessageHeader, response: [*]u8, capacity: u32, _: u64) callconv(.c) i32 {
        if (op == a.audio_service_op_status) {
            const status: a.AudioServiceStatus = .{};
            if (capacity < @sizeOf(@TypeOf(status))) return -1;
            @memcpy(response[0..@sizeOf(@TypeOf(status))], std.mem.asBytes(&status));
            header.* = .{ .op = op, .status = 0, .payload_len = @sizeOf(@TypeOf(status)) };
            return @sizeOf(@TypeOf(status));
        }
        if (capacity < @sizeOf(a.AudioServiceStreamResult)) return -1;
        var reply = a.AudioServiceStreamResult{ .action = op, .stream_id = 7 };
        switch (op) {
            a.audio_service_op_open_stream => {
                opens += 1;
                reply.result = 7;
            },
            a.audio_service_op_write_stream => {
                calls += 1;
                const began = now;
                now += write_cost;
                const n = @sizeOf(a.AudioServiceStreamWriteRequest);
                if (len < n) return -1;
                const req = std.mem.bytesToValue(a.AudioServiceStreamWriteRequest, bytes[0..n]);
                if (req.stream_id != 7 or req.byte_count != len - n or accepted + req.byte_count > pcm.len) return -1;
                const count: usize = if (calls <= initial_busy) 0 else if (fragmented and (calls - initial_busy) % 3 == 1) @min(400, req.byte_count) else if (fragmented and (calls - initial_busy) % 3 == 2) 0 else req.byte_count;
                @memcpy(pcm[accepted..][0..count], bytes[n..][0..count]);
                accepted += count;
                if (count != 0) {
                    if (first_write == null) first_write = began;
                    const anchor = resume_tick orelse first_write.?;
                    const base = if (resume_tick != null) resume_accepted else 0;
                    const elapsed_frames: u64 = @intCast(@as(u128, now - anchor) * source_rate / @max(hz, 1));
                    const lead = (accepted - base) / 4 -| elapsed_frames;
                    if (resume_tick != null) resume_largest_source_lead = @max(resume_largest_source_lead, lead) else largest_source_lead = @max(largest_source_lead, lead);
                }
                reply.result = if (count == 0) a.service_api_result_busy else @intCast(count);
                reply.bytes = @intCast(count);
            },
            a.audio_service_op_close_stream => {
                closes += 1;
                reply.result = close_result;
            },
            else => return -1,
        }
        @memcpy(response[0..@sizeOf(@TypeOf(reply))], std.mem.asBytes(&reply));
        header.* = .{ .op = op, .status = 0, .payload_len = @sizeOf(@TypeOf(reply)) };
        return @sizeOf(@TypeOf(reply));
    }
    fn run(args: [:0]const u8, ticks_available: bool) i32 {
        const raw = a.R4XStartContext{ .args = @intFromPtr(args.ptr), .args_len = @intCast(args.len) };
        var sys: a.R4XStartR4Sys = .{};
        sys.ticks = if (ticks_available) @intFromPtr(&ticks) else 0;
        sys.sleep_ticks = if (sleep_available) @intFromPtr(&sleep) else 0;
        sys.monotonic_clock = @intFromPtr(&clock);
        sys.write = @intFromPtr(&output);
        sys.file_read = @intFromPtr(&read);
        sys.service_open = @intFromPtr(&open);
        sys.service_close = @intFromPtr(&disconnect);
        sys.service_call = @intFromPtr(&call);
        var desk: a.R4XStartR4Desk = .{};
        desk.read_key = @intFromPtr(&key);
        const audio: a.R4XStartR4Audio = .{};
        var instance = r4os.App{ .raw = &raw, .bundle = .{ .raw = &raw, .sys = &sys, .audio = &audio, .desk = &desk }, .profile = .console };
        return app.r4_app_main(&instance);
    }
};

fn expectPcm(bytes: usize) !void {
    try t.expectEqual(bytes, Host.accepted);
    try t.expectEqualSlices(u8, Host.expected[0..bytes], Host.pcm[0..bytes]);
    try t.expectEqual(@as(usize, 1), Host.opens);
    try t.expectEqual(@as(usize, 1), Host.closes);
    try t.expectEqual(@as(usize, 1), Host.connections_closed);
}

test "fast WAV retains lead fractional duration and unchanged direct or converted PCM" {
    Host.reset();
    Host.wav(48_000, 2, 16, 9600);
    Host.file_cost = 500;
    try t.expectEqual(@as(i32, 0), Host.run("TEST.WAV", true));
    try expectPcm(Host.expected_len);
    try t.expectEqual(@as(u64, 700), Host.now);
    try t.expect(Host.largest_source_lead > 7680 and Host.largest_source_lead <= 7680 + 1019);
    Host.reset();
    Host.wav(44_100, 1, 8, 8820);
    try t.expectEqual(@as(i32, 0), Host.run("TEST.WAV", true));
    try expectPcm(Host.expected_len);
    try t.expectEqual(@as(u64, 200), Host.now);
    try t.expect(Host.largest_source_lead > 7056 and Host.largest_source_lead <= 7056 + 1019);
}

test "slow WAV write time already consumes the deadline and drain" {
    Host.reset();
    Host.wav(48_000, 2, 16, 9600);
    Host.write_cost = 25;
    try t.expectEqual(@as(i32, 0), Host.run("TEST.WAV", true));
    try expectPcm(Host.expected_len);
    try t.expectEqual(@as(u64, 250), Host.now);
    try t.expectEqual(@as(u64, 0), Host.slept);
    Host.reset();
    Host.wav(48_000, 2, 16, 9600);
    Host.initial_busy = 5;
    Host.write_cost = 40;
    try t.expectEqual(@as(i32, 0), Host.run("TEST.WAV", true));
    try expectPcm(Host.expected_len);
    try t.expectEqual(@as(u64, 605), Host.now);
    try t.expectEqual(@as(u64, 5), Host.slept);
}

test "WAV source and input work consume prior PCM budget but retain the new tail" {
    Host.reset();
    Host.wav(48_000, 2, 16, 9600);
    Host.key_cost = 30;
    try t.expectEqual(@as(i32, 0), Host.run("TEST.WAV", true));
    try expectPcm(Host.expected_len);
    try t.expectEqual(@as(u64, 309), Host.now);
    try t.expectEqual(@as(u64, 9), Host.slept);
}

test "WAV partial writes and Busy preserve the exact prefix without double time" {
    Host.reset();
    Host.wav(48_000, 2, 16, 9600);
    Host.fragmented = true;
    Host.write_cost = 25;
    try t.expectEqual(@as(i32, 0), Host.run("TEST.WAV", true));
    try expectPcm(Host.expected_len);
    try t.expectEqual(@as(usize, 30), Host.calls);
    try t.expectEqual(@as(u64, 750), Host.now);
    try t.expectEqual(@as(u64, 0), Host.slept);
}

test "long WAV pause consumes old budget and resume creates no burst credit" {
    Host.reset();
    Host.wav(48_000, 2, 16, 28_800);
    Host.pause = true;
    try t.expectEqual(@as(i32, 0), Host.run("TEST.WAV", true));
    try expectPcm(Host.expected_len);
    try t.expectEqual(@as(u64, 1540), Host.now);
    try t.expect(Host.resume_largest_source_lead > 7680 and Host.resume_largest_source_lead <= 7680 + 1019);
}

test "WAV Quit keeps its accepted prefix and still performs the real close" {
    Host.reset();
    Host.wav(48_000, 2, 16, 9600);
    Host.quit = true;
    try t.expectEqual(@as(i32, 0), Host.run("TEST.WAV", true));
    try expectPcm(3 * 4076);
    try t.expectEqual(@as(u64, 0), Host.now);
}

test "short SYNTH selftest waits only its own host budget and really closes" {
    Host.reset();
    try t.expectEqual(@as(i32, 0), Host.run("/SELFTEST", true));
    try t.expectEqual(@as(usize, 512), Host.accepted);
    try t.expectEqual(@as(usize, 1), Host.opens);
    try t.expectEqual(@as(usize, 1), Host.closes);
    try t.expectEqual(@as(u64, 3), Host.now);
}

test "SYNTH PCM rejects absent timing and never fabricates a close receipt" {
    Host.reset();
    Host.wav(48_000, 2, 16, 9600);
    try t.expect(Host.run("TEST.WAV", false) != 0);
    try t.expectEqual(@as(usize, 0), Host.opens);
    Host.reset();
    Host.wav(48_000, 2, 16, 9600);
    Host.hz = 0;
    try t.expect(Host.run("TEST.WAV", true) != 0);
    try t.expectEqual(@as(usize, 0), Host.opens);
    Host.reset();
    Host.wav(48_000, 2, 16, 9600);
    Host.sleep_available = false;
    try t.expect(Host.run("TEST.WAV", true) != 0);
    try t.expectEqual(@as(usize, 0), Host.opens);
    Host.reset();
    Host.wav(48_000, 2, 16, 9600);
    Host.close_result = a.service_api_result_busy;
    try t.expect(Host.run("TEST.WAV", true) != 0);
    try t.expectEqual(@as(usize, 1), Host.closes);
    try t.expectEqual(@as(usize, 0), Host.connections_closed);
}
