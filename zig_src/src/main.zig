const std = @import("std");
const c = @cImport({
    @cInclude("util.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("poll.h");
    @cInclude("termios.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("errno.h");
});

const Allocator = std.mem.Allocator;

// ── Low-level fd I/O helpers ────────────────────────────────────────────

fn readExact(fd: c_int, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.read(fd, @ptrCast(buf.ptr + total), buf.len - total);
        if (n <= 0) break;
        total += @as(usize, @intCast(n));
    }
    return total;
}

fn writeAllFd(fd: c_int, data: []const u8) void {
    var total: usize = 0;
    while (total < data.len) {
        const n = c.write(fd, @ptrCast(data.ptr + total), data.len - total);
        if (n <= 0) break;
        total += @as(usize, @intCast(n));
    }
}

// ── Packet-framed I/O ({:packet, 4} protocol) ──────────────────────────

fn readPacketFd(fd: c_int, buf: []u8) ![]u8 {
    var len_buf: [4]u8 = undefined;
    const hdr_n = readExact(fd, &len_buf);
    if (hdr_n < 4) return error.EndOfStream;

    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len == 0) return buf[0..0];
    if (len > buf.len) return error.MessageTooLarge;

    const body_n = readExact(fd, buf[0..len]);
    if (body_n < len) return error.EndOfStream;
    return buf[0..len];
}

fn writePacketFd(fd: c_int, data: []const u8) void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    writeAllFd(fd, &len_buf);
    writeAllFd(fd, data);
}

// ── Command parsing ─────────────────────────────────────────────────────

const SpawnCmd = struct {
    args: []const []const u8,
    rows: u16,
    cols: u16,
    workdir: ?[]const u8,
};

fn parseSpawnCmd(alloc: Allocator, data: []const u8) !SpawnCmd {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    const root = parsed.value.object;

    var rows: u16 = 24;
    var cols: u16 = 80;
    var workdir: ?[]const u8 = null;

    if (root.get("rows")) |v| {
        if (v == .integer) rows = @intCast(v.integer);
    }
    if (root.get("cols")) |v| {
        if (v == .integer) cols = @intCast(v.integer);
    }
    if (root.get("workdir")) |v| {
        if (v == .string) workdir = v.string;
    }

    const args_val = root.get("args") orelse return error.MissingArgs;
    if (args_val != .array) return error.InvalidArgs;

    // Use a fixed buffer for args (max 64 args)
    var args_buf: [64][]const u8 = undefined;
    var count: usize = 0;
    for (args_val.array.items) |item| {
        if (count >= 64) break;
        if (item == .string) {
            args_buf[count] = item.string;
            count += 1;
        }
    }

    // Copy to heap-allocated slice
    const args = try alloc.alloc([]const u8, count);
    @memcpy(args, args_buf[0..count]);

    return SpawnCmd{
        .args = args,
        .rows = rows,
        .cols = cols,
        .workdir = workdir,
    };
}

// ── PTY management ──────────────────────────────────────────────────────

fn setWinsize(fd: c_int, rows: u16, cols: u16) void {
    var ws: c.struct_winsize = .{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    _ = c.ioctl(fd, c.TIOCSWINSZ, &ws);
}

fn dupeZ(s: []const u8) [*c]u8 {
    // Create a null-terminated copy using libc malloc
    const ptr = c.malloc(s.len + 1) orelse return null;
    const buf: [*]u8 = @ptrCast(ptr);
    for (s, 0..) |byte, idx| {
        buf[idx] = byte;
    }
    buf[s.len] = 0;
    return buf;
}

fn doExec(cmd: SpawnCmd) noreturn {
    // Change working directory if specified
    if (cmd.workdir) |wd| {
        const wd_cstr = dupeZ(wd);
        if (wd_cstr != null) {
            _ = c.chdir(wd_cstr);
        }
    }

    // Build null-terminated argv as [*c]const [*c]u8 for execvp
    // Each string must be null-terminated for C
    var argv_buf: [256][*c]u8 = undefined;
    var i: usize = 0;
    for (cmd.args) |arg| {
        if (i >= 255) break;
        argv_buf[i] = dupeZ(arg);
        i += 1;
    }
    argv_buf[i] = null;

    const argv_ptr: [*c]const [*c]u8 = @ptrCast(&argv_buf);
    _ = c.execvp(argv_buf[0], argv_ptr);

    // If exec fails, exit
    c._exit(127);
}

fn handleElixirMessage(msg: []const u8, master_fd: c_int, child_pid: c.pid_t) void {
    // If it starts with '{', try to parse as JSON command
    if (msg.len > 0 and msg[0] == '{') {
        const alloc = std.heap.page_allocator;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, msg, .{}) catch {
            // Not valid JSON -- write raw to PTY
            _ = c.write(master_fd, @ptrCast(msg.ptr), msg.len);
            return;
        };
        defer parsed.deinit();
        const root = parsed.value.object;

        const cmd_val = root.get("cmd") orelse {
            _ = c.write(master_fd, @ptrCast(msg.ptr), msg.len);
            return;
        };
        if (cmd_val != .string) {
            _ = c.write(master_fd, @ptrCast(msg.ptr), msg.len);
            return;
        }

        const cmd_str = cmd_val.string;

        if (std.mem.eql(u8, cmd_str, "resize")) {
            var rows: u16 = 24;
            var cols: u16 = 80;
            if (root.get("rows")) |v| {
                if (v == .integer) rows = @intCast(v.integer);
            }
            if (root.get("cols")) |v| {
                if (v == .integer) cols = @intCast(v.integer);
            }
            setWinsize(master_fd, rows, cols);
        } else if (std.mem.eql(u8, cmd_str, "kill")) {
            _ = c.kill(child_pid, c.SIGTERM);
        } else if (std.mem.eql(u8, cmd_str, "interrupt")) {
            _ = c.kill(child_pid, c.SIGINT);
        } else {
            // Unknown command -- write raw
            _ = c.write(master_fd, @ptrCast(msg.ptr), msg.len);
        }
    } else {
        // Raw bytes -- write directly to PTY
        _ = c.write(master_fd, @ptrCast(msg.ptr), msg.len);
    }
}

// ── Main ────────────────────────────────────────────────────────────────

pub fn main() void {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa_instance.allocator();

    const stdout_fd: c_int = 1;
    const stdin_fd: c_int = 0;

    // Save stdout fd for packet protocol, then redirect stdout to stderr
    // so any accidental prints don't corrupt the protocol.
    const saved_stdout: c_int = c.dup(stdout_fd);
    if (saved_stdout < 0) {
        std.process.exit(1);
    }
    _ = c.dup2(2, stdout_fd); // stdout now goes to stderr

    // Read the first packet -- must be a spawn command
    var read_buf: [65536]u8 = undefined;
    const data = readPacketFd(stdin_fd, &read_buf) catch {
        writePacketFd(saved_stdout, "{\"event\":\"error\",\"msg\":\"failed to read spawn command\"}");
        std.process.exit(1);
    };

    // Parse spawn command
    const cmd = parseSpawnCmd(alloc, data) catch {
        writePacketFd(saved_stdout, "{\"event\":\"error\",\"msg\":\"invalid spawn command\"}");
        std.process.exit(1);
    };

    if (cmd.args.len == 0) {
        writePacketFd(saved_stdout, "{\"event\":\"error\",\"msg\":\"empty args\"}");
        std.process.exit(1);
    }

    // Set up initial winsize
    var ws: c.struct_winsize = .{
        .ws_row = cmd.rows,
        .ws_col = cmd.cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    // Fork with PTY
    var master_fd: c_int = undefined;
    const pid = c.forkpty(&master_fd, null, null, &ws);

    if (pid < 0) {
        writePacketFd(saved_stdout, "{\"event\":\"error\",\"msg\":\"forkpty failed\"}");
        std.process.exit(1);
    }

    if (pid == 0) {
        // Child process
        doExec(cmd);
    }

    // Parent process -- we have master_fd and pid
    writePacketFd(saved_stdout, "{\"event\":\"started\"}");

    // Main event loop using poll()
    var fds: [2]c.struct_pollfd = undefined;

    fds[0].fd = stdin_fd;
    fds[0].events = c.POLLIN;
    fds[0].revents = 0;

    fds[1].fd = master_fd;
    fds[1].events = c.POLLIN;
    fds[1].revents = 0;

    var pty_buf: [65536]u8 = undefined;
    var elixir_buf: [65536]u8 = undefined;

    while (true) {
        const poll_ret = c.poll(&fds, 2, 100); // 100ms timeout for child reaping

        if (poll_ret < 0) {
            const err = c.__error().*;
            if (err == c.EINTR) continue;
            break;
        }

        // Check for child exit (non-blocking)
        var status: c_int = 0;
        const wait_ret = c.waitpid(pid, &status, c.WNOHANG);
        if (wait_ret == pid) {
            // Child exited -- drain remaining PTY output
            while (true) {
                const n = c.read(master_fd, &pty_buf, pty_buf.len);
                if (n <= 0) break;
                const usize_n: usize = @intCast(n);
                writePacketFd(saved_stdout, pty_buf[0..usize_n]);
            }

            var exit_code: i32 = 0;
            if (c.WIFEXITED(status)) {
                exit_code = c.WEXITSTATUS(status);
            } else if (c.WIFSIGNALED(status)) {
                exit_code = 128 + c.WTERMSIG(status);
            }

            var exit_msg_buf: [128]u8 = undefined;
            const exit_msg = std.fmt.bufPrint(&exit_msg_buf, "{{\"event\":\"exit\",\"code\":{d}}}", .{exit_code}) catch break;
            writePacketFd(saved_stdout, exit_msg);
            break;
        }

        // Data from PTY -> send to Elixir
        if (fds[1].revents & c.POLLIN != 0) {
            const n = c.read(master_fd, &pty_buf, pty_buf.len);
            if (n > 0) {
                const usize_n: usize = @intCast(n);
                writePacketFd(saved_stdout, pty_buf[0..usize_n]);
            } else if (n <= 0) {
                // PTY closed
                fds[1].fd = -1;
            }
        }
        if (fds[1].revents & (c.POLLHUP | c.POLLERR) != 0) {
            fds[1].fd = -1;
        }

        // Data from Elixir -> handle command or write to PTY
        if (fds[0].revents & c.POLLIN != 0) {
            var len_bytes: [4]u8 = undefined;
            const hdr_n = readExact(stdin_fd, &len_bytes);
            if (hdr_n < 4) break; // Elixir closed stdin

            const msg_len = std.mem.readInt(u32, &len_bytes, .big);
            if (msg_len > elixir_buf.len) break;
            if (msg_len == 0) continue;

            const body_n = readExact(stdin_fd, elixir_buf[0..msg_len]);
            if (body_n < msg_len) break;

            const msg = elixir_buf[0..msg_len];
            handleElixirMessage(msg, master_fd, pid);
        }
        if (fds[0].revents & (c.POLLHUP | c.POLLERR) != 0) {
            // Elixir closed the port -- kill child and exit
            _ = c.kill(pid, c.SIGTERM);
            break;
        }
    }

    _ = c.close(master_fd);
    _ = c.close(saved_stdout);
}
