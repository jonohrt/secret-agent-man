# Secret Agent Man — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local web dashboard that manages multiple AI coding agent sessions with real-time, LLM-summarized activity feeds and embedded terminals.

**Architecture:** Elixir/Phoenix LiveView app with a Zig Port program for cross-platform PTY management. Each agent session gets an OTP process group (PTY, Parser, Summarizer, Server) under a DynamicSupervisor. LiveView pushes real-time updates; xterm.js provides raw terminal access via Phoenix Channels.

**Tech Stack:** Elixir 1.17+, Phoenix 1.7+, LiveView 1.0+, Zig 0.13+, xterm.js 5.x, Anthropic API (Haiku)

**Spec:** `docs/superpowers/specs/2026-03-19-secret-agent-man-design.md`

---

## Phase 1: Foundation

### Task 1: Install Toolchain

**Files:** None (system setup)

- [ ] **Step 1: Install Elixir via Homebrew**

```bash
brew install elixir
```

Verify: `elixir --version` shows 1.17+, `mix --version` works.

- [ ] **Step 2: Install Zig via Homebrew**

```bash
brew install zig
```

Verify: `zig version` shows 0.13+.

- [ ] **Step 3: Install hex and rebar**

```bash
mix local.hex --force
mix local.rebar --force
```

- [ ] **Step 4: Install Phoenix generator**

```bash
mix archive.install hex phx_new --force
```

### Task 2: Scaffold Phoenix Project

**Files:**
- Create: entire Phoenix project scaffold in `/Users/johrt/Code/secret-agent-man/`

- [ ] **Step 1: Generate Phoenix project (no Ecto, no mailer)**

```bash
cd /Users/johrt/Code
mix phx.new secret_agent_man --no-ecto --no-mailer --no-dashboard --no-gettext --app sam
```

Phoenix will ask to overwrite the directory. Say yes — our only files are in `docs/` and `.git/` which Phoenix won't touch.

Note: `--app sam` sets the OTP app name to `sam`, so modules are `Sam.*` and `SamWeb.*`.

- [ ] **Step 2: Verify the scaffold works**

```bash
cd /Users/johrt/Code/secret-agent-man
mix deps.get
mix compile
```

Expected: clean compilation, no errors.

- [ ] **Step 3: Verify Phoenix server starts**

```bash
mix phx.server
```

Visit `http://localhost:4000` — should see default Phoenix landing page. Stop with Ctrl+C.

- [ ] **Step 4: Add req dependency**

In `mix.exs`, add to `deps`:

```elixir
{:req, "~> 0.5"}
```

Run: `mix deps.get`

- [ ] **Step 5: Commit scaffold**

```bash
cd /Users/johrt/Code/secret-agent-man
echo ".superpowers/" >> .gitignore
git add -A
git commit -m "feat: scaffold Phoenix project with LiveView"
```

### Task 3: Zig PTY Port Program (POSIX)

This is the riskiest piece. We spike it first to prove the PTY layer works before building anything on top.

**Files:**
- Create: `zig_src/build.zig`
- Create: `zig_src/src/main.zig`
- Create: `Makefile`

- [ ] **Step 1: Create Zig build file**

Create `zig_src/build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "pty_port",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibC();

    b.installArtifact(exe);
}
```

- [ ] **Step 2: Create the PTY Port program**

Create `zig_src/src/main.zig`. The Port program:
1. Reads a command from stdin (first 4 bytes = length, then the command string)
2. Calls `forkpty()` to create a PTY and fork
3. Child: execs the command
4. Parent: relays data between the Elixir Port (stdin/stdout) and the PTY fd

Protocol over stdin/stdout (Elixir Port `{:packet, 4}`):
- Elixir → Port: `{"cmd": "spawn", "args": ["/bin/bash", "-l"]}` or raw bytes to write to PTY
- Port → Elixir: raw bytes from PTY output, or `{"event": "exit", "code": 0}`

```zig
const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("termios.h");
});

const PacketHeader = [4]u8;

fn readPacket(reader: anytype, buf: []u8) !?[]u8 {
    var header: PacketHeader = undefined;
    const header_read = reader.readAll(&header) catch return null;
    if (header_read < 4) return null;

    const len: u32 = std.mem.readInt(u32, &header, .big);
    if (len == 0 or len > buf.len) return null;

    const data_read = reader.readAll(buf[0..len]) catch return null;
    if (data_read < len) return null;
    return buf[0..len];
}

fn writePacket(writer: anytype, data: []const u8) !void {
    var header: PacketHeader = undefined;
    std.mem.writeInt(u32, &header, @intCast(data.len), .big);
    try writer.writeAll(&header);
    try writer.writeAll(data);
}

pub fn main() !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var buf: [65536]u8 = undefined;

    // Read the spawn command
    const spawn_data = (try readPacket(stdin, &buf)) orelse return;

    // Parse JSON to get the command
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, spawn_data, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;
    const args_json = root.get("args") orelse return;
    const args_array = args_json.array;

    // Build argv for exec
    var argv: [64:null]?[*:0]const u8 = .{null} ** 64;
    for (args_array.items, 0..) |arg, i| {
        if (i >= 63) break;
        const str = arg.string;
        // Copy to null-terminated buffer
        const duped = std.heap.page_allocator.dupeZ(u8, str) catch return;
        argv[i] = duped.ptr;
    }

    // Set up winsize
    var ws: c.struct_winsize = .{
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    // Check if caller sent rows/cols
    if (root.get("rows")) |rows_val| {
        if (rows_val == .integer) ws.ws_row = @intCast(rows_val.integer);
    }
    if (root.get("cols")) |cols_val| {
        if (cols_val == .integer) ws.ws_col = @intCast(cols_val.integer);
    }

    var master_fd: c_int = undefined;
    const pid = c.forkpty(&master_fd, null, null, &ws);

    if (pid < 0) {
        // forkpty failed
        try writePacket(stdout, "{\"event\":\"error\",\"msg\":\"forkpty failed\"}");
        return;
    }

    if (pid == 0) {
        // Child process — exec the command
        const result = std.posix.execvpeZ(argv[0].?, &argv, std.c.environ);
        _ = result;
        std.posix.exit(1);
    }

    // Parent: relay between stdin/stdout (Elixir) and master_fd (PTY)

    // Send success message
    try writePacket(stdout, "{\"event\":\"started\"}");

    // Set up poll
    var fds: [2]std.posix.pollfd = .{
        .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }, // stdin from Elixir
        .{ .fd = master_fd, .events = std.posix.POLL.IN, .revents = 0 }, // PTY output
    };

    var running = true;
    while (running) {
        const poll_result = std.posix.poll(&fds, -1) catch break;
        if (poll_result <= 0) continue;

        // Data from Elixir → PTY
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            const packet = readPacket(stdin, &buf) catch break orelse {
                running = false;
                break;
            };

            // Check if it's a control message (JSON) or raw data
            if (packet.len > 0 and packet[0] == '{') {
                // Parse as JSON control message
                const ctrl = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, packet, .{}) catch {
                    // Not valid JSON, treat as raw data
                    _ = posix.write(master_fd, packet) catch break;
                    continue;
                };
                defer ctrl.deinit();

                const ctrl_obj = ctrl.value.object;
                if (ctrl_obj.get("cmd")) |cmd_val| {
                    const cmd_str = cmd_val.string;
                    if (std.mem.eql(u8, cmd_str, "resize")) {
                        // Handle resize
                        var new_ws: c.struct_winsize = ws;
                        if (ctrl_obj.get("rows")) |r| {
                            if (r == .integer) new_ws.ws_row = @intCast(r.integer);
                        }
                        if (ctrl_obj.get("cols")) |cl| {
                            if (cl == .integer) new_ws.ws_col = @intCast(cl.integer);
                        }
                        _ = std.c.ioctl(master_fd, std.posix.T.IOCSWINSZ, @intFromPtr(&new_ws));
                        ws = new_ws;
                    } else if (std.mem.eql(u8, cmd_str, "kill")) {
                        _ = c.kill(pid, c.SIGTERM);
                    } else if (std.mem.eql(u8, cmd_str, "interrupt")) {
                        _ = c.kill(pid, c.SIGINT);
                    }
                }
            } else {
                // Raw data → write to PTY
                _ = posix.write(master_fd, packet) catch break;
            }
        }

        // Data from PTY → Elixir
        if (fds[1].revents & std.posix.POLL.IN != 0) {
            const n = posix.read(master_fd, &buf) catch break;
            if (n == 0) {
                running = false;
                break;
            }
            writePacket(stdout, buf[0..n]) catch break;
        }

        // PTY hung up
        if (fds[1].revents & std.posix.POLL.HUP != 0) {
            running = false;
        }
    }

    // Wait for child and report exit
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const exit_code = if (c.WIFEXITED(status)) c.WEXITSTATUS(status) else 1;

    var exit_buf: [64]u8 = undefined;
    const exit_msg = std.fmt.bufPrint(&exit_buf, "{{\"event\":\"exit\",\"code\":{d}}}", .{exit_code}) catch return;
    writePacket(stdout, exit_msg) catch {};
}
```

- [ ] **Step 3: Create Makefile**

Create `Makefile`:

```makefile
.PHONY: zig_build clean

PRIV_DIR = priv/native

zig_build:
	mkdir -p $(PRIV_DIR)
	cd zig_src && zig build -Doptimize=ReleaseSafe
	cp zig_src/zig-out/bin/pty_port $(PRIV_DIR)/pty_port

clean:
	rm -rf zig_src/zig-out zig_src/.zig-cache $(PRIV_DIR)/pty_port
```

- [ ] **Step 4: Build the Zig Port**

```bash
cd /Users/johrt/Code/secret-agent-man
make zig_build
```

Expected: `priv/native/pty_port` binary exists.

- [ ] **Step 5: Manual spike test from Elixir**

```bash
cd /Users/johrt/Code/secret-agent-man
iex -S mix
```

In IEx:

```elixir
port = Port.open({:spawn_executable, "priv/native/pty_port"}, [
  :binary, :exit_status, {:packet, 4}
])
# Send spawn command
Port.command(port, Jason.encode!(%{cmd: "spawn", args: ["/bin/bash", "-l"]}))
# Should receive {:started} message
flush()
# Send a command
Port.command(port, "echo hello\n")
# Should see PTY output
flush()
# Clean up
Port.command(port, Jason.encode!(%{cmd: "kill"}))
```

Expected: receive `{:started}` event, then see "hello" in the PTY output. This proves the entire PTY pipeline works.

- [ ] **Step 6: Commit**

```bash
git add zig_src/ Makefile priv/native/.gitkeep
echo "zig_src/zig-out/" >> .gitignore
echo "zig_src/.zig-cache/" >> .gitignore
echo "priv/native/pty_port" >> .gitignore
git add .gitignore
git commit -m "feat: add Zig PTY Port program with forkpty relay"
```

---

## Phase 2: Session Process Tree

### Task 4: Session.PTY GenServer

**Files:**
- Create: `lib/sam/session/pty.ex`
- Create: `test/sam/session/pty_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/sam/session/pty_test.exs`:

```elixir
defmodule Sam.Session.PTYTest do
  use ExUnit.Case, async: false

  @pty_port_path Path.join(:code.priv_dir(:sam), "native/pty_port")

  describe "start_link/1" do
    test "spawns a shell and receives output" do
      {:ok, pid} = Sam.Session.PTY.start_link(%{
        command: ["/bin/bash", "-l"],
        session_id: "test-1"
      })

      # Send a command
      Sam.Session.PTY.send_input(pid, "echo sam_test_marker\n")

      # Wait for output
      assert_receive {:pty_output, "test-1", data}, 5000
      assert String.contains?(data, "sam_test_marker")

      # Clean up
      Sam.Session.PTY.stop(pid)
    end
  end

  describe "send_input/2" do
    test "writes raw data to the PTY" do
      {:ok, pid} = Sam.Session.PTY.start_link(%{
        command: ["/bin/bash", "-l"],
        session_id: "test-2"
      })

      Sam.Session.PTY.send_input(pid, "echo hello_from_pty\n")

      assert_receive {:pty_output, "test-2", data}, 5000
      assert String.contains?(data, "hello_from_pty")

      Sam.Session.PTY.stop(pid)
    end
  end

  describe "resize/3" do
    test "sends resize command without crashing" do
      {:ok, pid} = Sam.Session.PTY.start_link(%{
        command: ["/bin/bash", "-l"],
        session_id: "test-3"
      })

      assert :ok = Sam.Session.PTY.resize(pid, 120, 40)

      Sam.Session.PTY.stop(pid)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/sam/session/pty_test.exs
```

Expected: FAIL — `Sam.Session.PTY` module not found.

- [ ] **Step 3: Implement Session.PTY**

Create `lib/sam/session/pty.ex`:

All inter-process communication uses PubSub instead of direct `send/2`. This allows proper OTP supervision — no process needs a reference to another's PID.

```elixir
defmodule Sam.Session.PTY do
  use GenServer
  require Logger

  defstruct [:port, :session_id, :workdir]

  defp pty_port_path, do: Path.join(:code.priv_dir(:sam), "native/pty_port")

  ## Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def send_input(pid, data) when is_binary(data) do
    GenServer.cast(pid, {:input, data})
  end

  def resize(pid, cols, rows) do
    GenServer.cast(pid, {:resize, cols, rows})
  end

  def stop(pid) do
    GenServer.cast(pid, {:control, "kill"})
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    command = Map.fetch!(opts, :command)
    session_id = Map.fetch!(opts, :session_id)
    workdir = Map.get(opts, :workdir)
    rows = Map.get(opts, :rows, 24)
    cols = Map.get(opts, :cols, 80)

    port = Port.open({:spawn_executable, pty_port_path()}, [
      :binary, :exit_status, {:packet, 4}
    ])

    spawn_msg = Jason.encode!(%{
      cmd: "spawn",
      args: command,
      rows: rows,
      cols: cols,
      workdir: workdir
    })

    Port.command(port, spawn_msg)

    {:ok, %__MODULE__{
      port: port,
      session_id: session_id,
      workdir: workdir
    }}
  end

  @impl true
  def handle_cast({:input, data}, state) do
    Port.command(state.port, data)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:resize, cols, rows}, state) do
    msg = Jason.encode!(%{cmd: "resize", rows: rows, cols: cols})
    Port.command(state.port, msg)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:control, cmd}, state) do
    msg = Jason.encode!(%{cmd: cmd})
    Port.command(state.port, msg)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Jason.decode(data) do
      {:ok, %{"event" => "started"}} ->
        Logger.debug("PTY started for session #{state.session_id}")
        {:noreply, state}

      {:ok, %{"event" => "exit", "code" => code}} ->
        Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{state.session_id}", {:pty_exit, state.session_id, code})
        {:stop, :normal, state}

      {:ok, %{"event" => "error", "msg" => msg}} ->
        Logger.error("PTY error for session #{state.session_id}: #{msg}")
        {:stop, {:error, msg}, state}

      _ ->
        # Raw PTY output → broadcast to Parser, TerminalChannel, etc.
        Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{state.session_id}", {:pty_output, state.session_id, data})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{state.session_id}", {:pty_exit, state.session_id, status})
    {:stop, :normal, state}
  end
end
```

**Note on workdir:** The Zig Port program also needs to handle `workdir` — in the child process (after fork, before exec), call `chdir(workdir)`. Add this to the Zig code in Task 3 Step 2:

```zig
// In child process, before exec:
if (root.get("workdir")) |wd_val| {
    if (wd_val == .string) {
        const wd = std.heap.page_allocator.dupeZ(u8, wd_val.string) catch {};
        _ = std.posix.chdir(wd) catch {};
    }
}
```

**Note on tests:** The PTY test needs to use PubSub. Update the test to subscribe:

```elixir
# In test setup:
Phoenix.PubSub.subscribe(Sam.PubSub, "session:test-1")
# Then assert_receive {:pty_output, "test-1", data} works via PubSub
```

- [ ] **Step 4: Run tests**

```bash
make zig_build && mix test test/sam/session/pty_test.exs
```

Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/sam/session/pty.ex test/sam/session/pty_test.exs
git commit -m "feat: add Session.PTY GenServer wrapping Zig Port"
```

### Task 5: Session.Parser GenServer

**Files:**
- Create: `lib/sam/session/parser.ex`
- Create: `test/sam/session/parser_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/sam/session/parser_test.exs`:

```elixir
defmodule Sam.Session.ParserTest do
  use ExUnit.Case, async: true

  describe "parse_output/2" do
    test "strips ANSI escape sequences" do
      raw = "\e[32mhello\e[0m world"
      assert Sam.Session.Parser.strip_ansi(raw) == "hello world"
    end

    test "detects input-needed patterns" do
      assert Sam.Session.Parser.input_needed?("? Allow Read tool on file.txt (y/N)")
      assert Sam.Session.Parser.input_needed?("Do you want to proceed? [y/N]")
      assert Sam.Session.Parser.input_needed?("Press enter to continue")
      refute Sam.Session.Parser.input_needed?("Compiling 5 files...")
    end

    test "processes hook events" do
      event = %{
        "event" => "tool_call",
        "tool" => "Edit",
        "file" => "src/auth.ts",
        "session_id" => "abc"
      }

      parsed = Sam.Session.Parser.parse_hook_event(event)
      assert parsed.type == :tool_call
      assert parsed.tool == "Edit"
      assert parsed.file == "src/auth.ts"
    end
  end

  describe "GenServer accumulation" do
    test "buffers raw output and emits events on quiescence" do
      {:ok, pid} = Sam.Session.Parser.start_link(%{
        session_id: "test-1",
        subscriber: self(),
        quiescence_ms: 100
      })

      Sam.Session.Parser.push_output(pid, "Searching for files...\n")
      Sam.Session.Parser.push_output(pid, "Found 3 matches\n")

      # Wait for quiescence timer
      assert_receive {:parser_event, "test-1", %{type: :activity, lines: lines}}, 500
      assert length(lines) == 2
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/sam/session/parser_test.exs
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement Session.Parser**

Create `lib/sam/session/parser.ex`:

```elixir
defmodule Sam.Session.Parser do
  use GenServer

  defstruct [:session_id, :quiescence_ms, :timer_ref, buffer: []]

  @default_quiescence_ms 3_000
  @ansi_regex ~r/\e\[[0-9;]*[a-zA-Z]|\e\].*?(?:\e\\|\x07)|\e[()][AB012]|\e[>=<]|\e\[[\?]?[0-9;]*[hlm]/

  ## Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def push_output(pid, data) when is_binary(data) do
    GenServer.cast(pid, {:output, data})
  end

  def push_hook_event(pid, event) when is_map(event) do
    GenServer.cast(pid, {:hook_event, event})
  end

  ## Pure functions (no GenServer needed)

  def strip_ansi(text) do
    Regex.replace(@ansi_regex, text, "")
  end

  def input_needed?(text) do
    stripped = strip_ansi(text)
    patterns = [
      ~r/\?\s+Allow/i,
      ~r/\[y\/N\]/i,
      ~r/\[Y\/n\]/i,
      ~r/\(y\/N\)/i,
      ~r/\(Y\/n\)/i,
      ~r/[Pp]ress enter/i,
      ~r/[Cc]ontinue\?/,
      ~r/[Pp]roceed\?/
    ]

    Enum.any?(patterns, &Regex.match?(&1, stripped))
  end

  def parse_hook_event(event) do
    %{
      type: String.to_atom(event["event"]),
      tool: event["tool"],
      file: event["file"],
      session_id: event["session_id"],
      timestamp: DateTime.utc_now()
    }
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    # Subscribe to PTY output for this session
    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    {:ok, %__MODULE__{
      session_id: session_id,
      quiescence_ms: Map.get(opts, :quiescence_ms, @default_quiescence_ms)
    }}
  end

  # Receive PTY output via PubSub
  @impl true
  def handle_info({:pty_output, _session_id, data}, state) do
    handle_cast({:output, data}, state)
  end

  @impl true
  def handle_cast({:output, data}, state) do
    stripped = strip_ansi(data)
    lines = stripped |> String.split("\n", trim: true)

    # Check for input-needed
    if input_needed?(data) do
      Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{state.session_id}", {:parser_event, state.session_id, %{type: :input_needed}})
    end

    # Buffer lines and reset quiescence timer
    state = cancel_timer(state)
    timer_ref = Process.send_after(self(), :quiescence, state.quiescence_ms)

    {:noreply, %{state | buffer: state.buffer ++ lines, timer_ref: timer_ref}}
  end

  @impl true
  def handle_cast({:hook_event, event}, state) do
    parsed = parse_hook_event(event)
    Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{state.session_id}", {:parser_event, state.session_id, parsed})

    # Hook events are also decision points — flush buffer
    state = flush_buffer(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:quiescence, state) do
    state = flush_buffer(state)
    {:noreply, %{state | timer_ref: nil}}
  end

  defp flush_buffer(%{buffer: []} = state), do: state

  defp flush_buffer(state) do
    Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{state.session_id}", {:parser_event, state.session_id, %{
      type: :activity,
      lines: state.buffer,
      timestamp: DateTime.utc_now()
    }})
    %{state | buffer: []}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state
  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/sam/session/parser_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/sam/session/parser.ex test/sam/session/parser_test.exs
git commit -m "feat: add Session.Parser with ANSI stripping and quiescence detection"
```

### Task 6: LLM Client + Session.Summarizer

**Files:**
- Create: `lib/sam/llm/client.ex`
- Create: `lib/sam/session/summarizer.ex`
- Create: `test/sam/session/summarizer_test.exs`

- [ ] **Step 1: Create LLM client**

Create `lib/sam/llm/client.ex`:

```elixir
defmodule Sam.LLM.Client do
  @moduledoc "Anthropic API client for activity summarization."

  @default_model "claude-haiku-4-5-20251001"

  def summarize(lines, opts \\ []) when is_list(lines) do
    api_key = Application.get_env(:sam, :anthropic_api_key) || System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      {:ok, Enum.join(lines, " | ")}
    else
      model = Keyword.get(opts, :model, @default_model)
      prompt = """
      Summarize what happened in this sequence of AI coding agent actions in one sentence.
      Focus on the outcome, not the process. Be concise.

      Actions:
      #{Enum.join(lines, "\n")}
      """

      body = %{
        model: model,
        max_tokens: 150,
        messages: [%{role: "user", content: prompt}]
      }

      case Req.post("https://api.anthropic.com/v1/messages",
        json: body,
        headers: [
          {"x-api-key", api_key},
          {"anthropic-version", "2023-06-01"}
        ]
      ) do
        {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
          {:ok, String.trim(text)}

        {:ok, %{status: status, body: body}} ->
          {:error, "API error #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
```

- [ ] **Step 2: Write the failing test for Summarizer**

Create `test/sam/session/summarizer_test.exs`:

```elixir
defmodule Sam.Session.SummarizerTest do
  use ExUnit.Case, async: true

  describe "start_link/1" do
    test "buffers events and produces summaries on decision points" do
      {:ok, pid} = Sam.Session.Summarizer.start_link(%{
        session_id: "test-1",
        subscriber: self(),
        debounce_ms: 50
      })

      # Push activity events
      Sam.Session.Summarizer.push_event(pid, %{
        type: :activity,
        lines: ["Searching codebase for auth handler", "Found 3 files matching"],
        timestamp: DateTime.utc_now()
      })

      # Push a decision point (hook event)
      Sam.Session.Summarizer.push_event(pid, %{
        type: :tool_call,
        tool: "Edit",
        file: "src/auth.ts",
        timestamp: DateTime.utc_now()
      })

      # Should receive a summary
      assert_receive {:summary, "test-1", %{summary: summary, raw_events: events}}, 2000
      assert is_binary(summary)
      assert length(events) == 2
    end
  end

  describe "without API key" do
    test "falls back to joining lines" do
      {:ok, pid} = Sam.Session.Summarizer.start_link(%{
        session_id: "test-2",
        subscriber: self(),
        debounce_ms: 50
      })

      Sam.Session.Summarizer.push_event(pid, %{
        type: :activity,
        lines: ["line one", "line two"],
        timestamp: DateTime.utc_now()
      })

      Sam.Session.Summarizer.push_event(pid, %{
        type: :input_needed,
        timestamp: DateTime.utc_now()
      })

      assert_receive {:summary, "test-2", %{summary: summary}}, 2000
      assert String.contains?(summary, "line one")
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

```bash
mix test test/sam/session/summarizer_test.exs
```

Expected: FAIL — module not found.

- [ ] **Step 4: Implement Session.Summarizer**

Create `lib/sam/session/summarizer.ex`:

```elixir
defmodule Sam.Session.Summarizer do
  use GenServer

  @default_debounce_ms 5_000
  @decision_point_types [:tool_call, :input_needed, :agent_spawn, :completion]

  defstruct [:session_id, :debounce_ms, :timer_ref, buffer: []]

  ## Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def push_event(pid, event) do
    GenServer.cast(pid, {:event, event})
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    # Subscribe to parser events for this session
    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    {:ok, %__MODULE__{
      session_id: session_id,
      debounce_ms: Map.get(opts, :debounce_ms, @default_debounce_ms)
    }}
  end

  # Receive parser events via PubSub
  @impl true
  def handle_info({:parser_event, _session_id, event}, state) do
    handle_cast({:event, event}, state)
  end

  @impl true
  def handle_cast({:event, event}, state) do
    state = %{state | buffer: state.buffer ++ [event]}

    if event.type in @decision_point_types do
      # Decision point — schedule summary (debounced)
      state = schedule_summary(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:summarize, state) do
    state = do_summarize(state)
    {:noreply, %{state | timer_ref: nil}}
  end

  defp schedule_summary(state) do
    state = cancel_timer(state)
    ref = Process.send_after(self(), :summarize, state.debounce_ms)
    %{state | timer_ref: ref}
  end

  defp do_summarize(%{buffer: []} = state), do: state

  defp do_summarize(state) do
    # Collect all lines from activity events
    all_lines =
      state.buffer
      |> Enum.flat_map(fn
        %{type: :activity, lines: lines} -> lines
        %{type: :tool_call, tool: tool, file: file} -> ["Used #{tool} on #{file}"]
        %{type: :input_needed} -> ["Waiting for user input"]
        %{type: :agent_spawn, description: desc} -> ["Spawned agent: #{desc}"]
        _ -> []
      end)

    # Summarize
    summary = case Sam.LLM.Client.summarize(all_lines) do
      {:ok, text} -> text
      {:error, _} -> Enum.join(all_lines, " | ")
    end

    Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{state.session_id}", {:summary, state.session_id, %{
      summary: summary,
      raw_events: state.buffer,
      timestamp: DateTime.utc_now()
    }})

    %{state | buffer: []}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state
  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
```

- [ ] **Step 5: Run tests**

```bash
mix test test/sam/session/summarizer_test.exs
```

Expected: all tests pass (using fallback summarization since no API key in test).

- [ ] **Step 6: Commit**

```bash
git add lib/sam/llm/client.ex lib/sam/session/summarizer.ex test/sam/session/summarizer_test.exs
git commit -m "feat: add LLM client and Session.Summarizer with decision-point detection"
```

### Task 7: Session.Server + Registry + GroupSupervisor

**Files:**
- Create: `lib/sam/session/server.ex`
- Create: `lib/sam/session/registry.ex`
- Create: `lib/sam/session/group_supervisor.ex`
- Create: `test/sam/session/server_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/sam/session/server_test.exs`:

```elixir
defmodule Sam.Session.ServerTest do
  use ExUnit.Case, async: false

  describe "session lifecycle" do
    test "creates a session, spawns agent, receives summaries" do
      session_id = "test-#{System.unique_integer([:positive])}"

      {:ok, _pid} = Sam.Session.GroupSupervisor.start_link(%{
        session_id: session_id,
        command: ["/bin/bash", "-l"],
        agent_type: :generic,
        name: "Test Session",
        subscriber: self()
      })

      # Session should be running
      state = Sam.Session.Server.get_state(session_id)
      assert state.status in [:starting, :running]
      assert state.name == "Test Session"

      # Send input through the session
      Sam.Session.Server.send_input(session_id, "echo lifecycle_test\n")

      # Should eventually get activity
      assert_receive {:session_update, ^session_id, _update}, 5000

      # Clean up
      Sam.Session.Server.stop(session_id)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/sam/session/server_test.exs
```

Expected: FAIL — modules not found.

- [ ] **Step 3: Implement Session.Server**

No custom ETS registry needed — we use Elixir's built-in `Registry` module (`Sam.ProcessRegistry`) for named process lookup, and PubSub for all event routing.

Create `lib/sam/session/server.ex`:

The Server uses a single Elixir `Registry` for named lookup and PubSub for all event routing. No ETS-based custom registry needed.

```elixir
defmodule Sam.Session.Server do
  use GenServer
  require Logger

  defstruct [
    :session_id, :name, :agent_type, :branch, :workdir,
    status: :starting,
    activity: [],
    agents: []
  ]

  ## Public API

  def start_link(opts) do
    session_id = Map.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  def get_state(session_id) do
    GenServer.call(via(session_id), :get_state)
  end

  def send_input(session_id, data) do
    GenServer.cast(via(session_id), {:send_input, data})
  end

  def resize(session_id, cols, rows) do
    GenServer.cast(via(session_id), {:resize, cols, rows})
  end

  def push_hook_event(session_id, event) do
    GenServer.cast(via(session_id), {:hook_event, event})
  end

  def stop(session_id) do
    GenServer.cast(via(session_id), :stop)
  end

  @doc "List all registered session IDs"
  def list_sessions do
    Registry.select(Sam.ProcessRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp via(session_id), do: {:via, Registry, {Sam.ProcessRegistry, session_id}}

  ## GenServer callbacks

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)

    # Subscribe to all session events via PubSub
    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    state = %__MODULE__{
      session_id: session_id,
      name: Map.get(opts, :name, session_id),
      agent_type: Map.get(opts, :agent_type, :generic),
      workdir: Map.get(opts, :workdir),
      status: :running
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:send_input, data}, state) do
    # Broadcast input to the PTY (which is also subscribed? No — PTY doesn't subscribe)
    # Instead, look up PTY in the supervisor's children. Simpler: use a named PTY process.
    # Actually, we use a dedicated PubSub topic for input:
    Phoenix.PubSub.broadcast(Sam.PubSub, "session_input:#{state.session_id}", {:input, data})
    {:noreply, %{state | status: :running}}
  end

  @impl true
  def handle_cast({:resize, cols, rows}, state) do
    Phoenix.PubSub.broadcast(Sam.PubSub, "session_input:#{state.session_id}", {:resize, cols, rows})
    {:noreply, state}
  end

  @impl true
  def handle_cast(:stop, state) do
    Phoenix.PubSub.broadcast(Sam.PubSub, "session_input:#{state.session_id}", :kill)
    {:stop, :normal, state}
  end

  @impl true
  def handle_cast({:hook_event, event}, state) do
    # Broadcast as parser event so the Summarizer picks it up
    Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{state.session_id}",
      {:parser_event, state.session_id, Sam.Session.Parser.parse_hook_event(event)})
    {:noreply, state}
  end

  ## PubSub event handlers

  @impl true
  def handle_info({:parser_event, _session_id, %{type: :input_needed}}, state) do
    state = %{state | status: :needs_input}
    broadcast_ui_update(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:parser_event, _session_id, _event}, state) do
    # Parser events are also picked up by Summarizer via PubSub — no forwarding needed
    {:noreply, state}
  end

  @impl true
  def handle_info({:summary, _session_id, summary}, state) do
    activity = [summary | state.activity] |> Enum.take(100)
    state = %{state | activity: activity}
    broadcast_ui_update(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pty_output, _session_id, _data}, state) do
    # PTY output is handled by Parser via PubSub — Server doesn't need to act on raw output
    {:noreply, state}
  end

  @impl true
  def handle_info({:pty_exit, _session_id, 0}, state) do
    state = %{state | status: :done}
    broadcast_ui_update(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pty_exit, _session_id, _code}, state) do
    state = %{state | status: :error}
    broadcast_ui_update(state)
    {:noreply, state}
  end

  defp broadcast_ui_update(state) do
    Phoenix.PubSub.broadcast(Sam.PubSub, "sessions:ui", {:session_update, state.session_id, state})
  end
end
```

**Note:** The PTY process needs to subscribe to `"session_input:#{session_id}"` to receive input/resize/kill commands. Add to `Session.PTY.init`:

```elixir
Phoenix.PubSub.subscribe(Sam.PubSub, "session_input:#{session_id}")
```

And add handlers:

```elixir
@impl true
def handle_info({:input, data}, state) do
  Port.command(state.port, data)
  {:noreply, state}
end

@impl true
def handle_info({:resize, cols, rows}, state) do
  msg = Jason.encode!(%{cmd: "resize", rows: rows, cols: cols})
  Port.command(state.port, msg)
  {:noreply, state}
end

@impl true
def handle_info(:kill, state) do
  msg = Jason.encode!(%{cmd: "kill"})
  Port.command(state.port, msg)
  {:noreply, state}
end
```

- [ ] **Step 5: Implement Session.GroupSupervisor**

Create `lib/sam/session/group_supervisor.ex`:

Since all processes communicate via PubSub (not direct `send/2`), they don't need each other's PIDs. This makes the Supervisor trivially clean:

```elixir
defmodule Sam.Session.GroupSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    command = Map.fetch!(opts, :command)

    children = [
      # Server first — registers in Registry, subscribes to PubSub
      %{
        id: Sam.Session.Server,
        start: {Sam.Session.Server, :start_link, [opts]}
      },
      # Summarizer subscribes to session PubSub for parser events
      %{
        id: Sam.Session.Summarizer,
        start: {Sam.Session.Summarizer, :start_link, [%{session_id: session_id}]}
      },
      # Parser subscribes to session PubSub for PTY output
      %{
        id: Sam.Session.Parser,
        start: {Sam.Session.Parser, :start_link, [%{session_id: session_id}]}
      },
      # PTY broadcasts all output to session PubSub
      %{
        id: Sam.Session.PTY,
        start: {Sam.Session.PTY, :start_link, [%{
          session_id: session_id,
          command: command,
          workdir: Map.get(opts, :workdir)
        }]}
      }
    ]

    # rest_for_one: if PTY dies, Parser/Summarizer/Server restart
    # (they'll re-subscribe to PubSub on init)
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

**Key insight:** PubSub decouples the processes. Each process subscribes to `"session:#{session_id}"` on init and broadcasts events there. No PID passing, no wiring, and `rest_for_one` just works — restarted processes re-subscribe automatically.

- [ ] **Step 5: Update Application supervisor**

Ensure `lib/sam/application.ex` has these in the children list (Phoenix scaffold may already include PubSub):

```elixir
{Phoenix.PubSub, name: Sam.PubSub},
{Registry, keys: :unique, name: Sam.ProcessRegistry},
{DynamicSupervisor, name: Sam.SessionSupervisor, strategy: :one_for_one},
```

The `DynamicSupervisor` is used to start `GroupSupervisor` instances dynamically when sessions are created. Update `GroupSupervisor.start_session/1`:

```elixir
def start_session(opts) do
  DynamicSupervisor.start_child(Sam.SessionSupervisor, {__MODULE__, opts})
end
```

- [ ] **Step 7: Run tests**

```bash
mix test test/sam/session/server_test.exs
```

Expected: tests pass — session starts, receives updates, stops cleanly.

- [ ] **Step 8: Commit**

```bash
git add lib/sam/session/server.ex lib/sam/session/registry.ex lib/sam/session/group_supervisor.ex lib/sam/application.ex test/sam/session/server_test.exs
git commit -m "feat: add Session.Server, Registry, and GroupSupervisor"
```

---

## Phase 3: Web Layer

### Task 8: Dashboard LiveView — Tab Bar + Basic Layout

**Files:**
- Create: `lib/sam_web/live/dashboard_live.ex`
- Modify: `lib/sam_web/router.ex` — add LiveView route
- Modify: `lib/sam_web/layouts/root.html.heex` — theme class on body
- Create: `assets/css/themes.css` — Tron theme CSS variables

- [ ] **Step 1: Add route**

In `lib/sam_web/router.ex`, in the browser pipeline scope, add:

```elixir
live "/", DashboardLive
```

Remove or replace the default PageController route.

- [ ] **Step 2: Create DashboardLive**

Create `lib/sam_web/live/dashboard_live.ex`:

```elixir
defmodule SamWeb.DashboardLive do
  use SamWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to UI updates from all sessions
      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")
    end

    sessions = Sam.Session.Server.list_sessions()
    |> Enum.map(fn id -> Sam.Session.Server.get_state(id) end)

    {:ok, assign(socket,
      sessions: sessions,
      active_session: nil,
      show_terminal: false,
      show_new_dialog: false
    )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="dashboard">
      <!-- Tab Bar -->
      <div class="tab-bar">
        <div
          :for={session <- @sessions}
          class={["tab", @active_session && @active_session.session_id == session.session_id && "tab--active"]}
          phx-click="select_session"
          phx-value-id={session.session_id}
        >
          <span class={["status-dot", "status-dot--#{session.status}"]}></span>
          <span class="tab__name"><%= session.name %></span>
          <span class="tab__branch"><%= session.branch || "" %></span>
        </div>
        <button class="tab tab--new" phx-click="toggle_new_dialog">+</button>
      </div>

      <!-- Main Panel -->
      <%= if @active_session do %>
        <div class="main-panel">
          <div class="panel-left">
            <div class="status-badge status-badge--{@active_session.status}">
              <%= status_label(@active_session.status) %>
            </div>
            <h2 class="task-description"><%= @active_session.name %></h2>

            <!-- Activity Feed -->
            <div class="activity-feed">
              <div :for={entry <- @active_session.activity} class="activity-entry">
                <span class="activity-time"><%= format_time(entry.timestamp) %></span>
                <span class="activity-text"><%= entry.summary %></span>
              </div>
              <div :if={@active_session.activity == []} class="activity-empty">
                No activity yet...
              </div>
            </div>

            <!-- Input bar (when needs input) -->
            <%= if @active_session.status == :needs_input do %>
              <div class="input-bar">
                <div class="quick-actions">
                  <button phx-click="quick_respond" phx-value-response="y" class="btn-quick">Yes</button>
                  <button phx-click="quick_respond" phx-value-response="n" class="btn-quick">No</button>
                </div>
                <form phx-submit="send_input" class="input-form">
                  <input type="text" name="input" placeholder="Type a response..." class="input-field" autofocus />
                  <button type="submit" class="btn-send">Send</button>
                </form>
              </div>
            <% end %>
          </div>

          <div class="panel-right">
            <!-- Agents -->
            <div class="section-header">AGENTS</div>
            <div class="agent-list">
              <div :for={agent <- @active_session.agents} class="agent-card">
                <span class="agent-name"><%= agent.name %></span>
                <span class={["status-dot", "status-dot--#{agent.status}"]}></span>
              </div>
              <div :if={@active_session.agents == []} class="agents-empty">
                No subagents
              </div>
            </div>

            <!-- Terminal toggle -->
            <button phx-click="toggle_terminal" class="btn-terminal">
              <%= if @show_terminal, do: "← Structured View", else: "Open Terminal →" %>
            </button>
          </div>
        </div>

        <!-- Terminal overlay -->
        <%= if @show_terminal do %>
          <div id="terminal-container" phx-hook="Terminal" data-session-id={@active_session.session_id}>
            <div id="terminal"></div>
          </div>
        <% end %>
      <% else %>
        <div class="empty-state">
          <p>No session selected. Click + to create one.</p>
        </div>
      <% end %>

      <!-- New Session Dialog -->
      <%= if @show_new_dialog do %>
        <div class="dialog-overlay" phx-click="toggle_new_dialog">
          <div class="dialog" phx-click-away="toggle_new_dialog">
            <h3>New Session</h3>
            <form phx-submit="create_session">
              <label>Agent</label>
              <select name="agent_type">
                <option value="claude_code">Claude Code</option>
                <option value="opencode">OpenCode</option>
                <option value="codex">Codex CLI</option>
                <option value="gemini">Gemini CLI</option>
                <option value="copilot">Copilot CLI</option>
              </select>

              <label>Directory</label>
              <input type="text" name="workdir" placeholder="/path/to/project" value={System.get_env("HOME")} />

              <label>Task / Prompt</label>
              <textarea name="prompt" placeholder="What should the agent work on?" rows="3"></textarea>

              <button type="submit" class="btn-create">Launch</button>
            </form>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  ## Event Handlers

  @impl true
  def handle_event("select_session", %{"id" => id}, socket) do
    session = Enum.find(socket.assigns.sessions, &(&1.session_id == id))
    {:noreply, assign(socket, active_session: session, show_terminal: false)}
  end

  @impl true
  def handle_event("toggle_new_dialog", _, socket) do
    {:noreply, assign(socket, show_new_dialog: !socket.assigns.show_new_dialog)}
  end

  @impl true
  def handle_event("toggle_terminal", _, socket) do
    {:noreply, assign(socket, show_terminal: !socket.assigns.show_terminal)}
  end

  @impl true
  def handle_event("send_input", %{"input" => input}, socket) do
    if session = socket.assigns.active_session do
      Sam.Session.Server.send_input(session.session_id, input <> "\n")
    end
    {:noreply, socket}
  end

  @impl true
  def handle_event("quick_respond", %{"response" => response}, socket) do
    if session = socket.assigns.active_session do
      Sam.Session.Server.send_input(session.session_id, response <> "\n")
    end
    {:noreply, socket}
  end

  @impl true
  def handle_event("create_session", params, socket) do
    agent_type = String.to_existing_atom(params["agent_type"])
    workdir = params["workdir"]
    prompt = params["prompt"]

    command = agent_command(agent_type, workdir, prompt)
    session_id = "sam-#{System.unique_integer([:positive])}"

    {:ok, _} = Sam.Session.GroupSupervisor.start_session(%{
      session_id: session_id,
      command: command,
      agent_type: agent_type,
      name: Path.basename(workdir),
      workdir: workdir
    })

    sessions = refresh_sessions()
    active = Enum.find(sessions, &(&1.session_id == session_id))

    {:noreply, assign(socket,
      sessions: sessions,
      active_session: active,
      show_new_dialog: false
    )}
  end

  ## PubSub handler

  @impl true
  def handle_info({:session_update, session_id, update}, socket) do
    sessions = socket.assigns.sessions
    |> Enum.map(fn s ->
      if s.session_id == session_id, do: update, else: s
    end)

    active = if socket.assigns.active_session &&
                socket.assigns.active_session.session_id == session_id do
      update
    else
      socket.assigns.active_session
    end

    {:noreply, assign(socket, sessions: sessions, active_session: active)}
  end

  ## Helpers

  defp refresh_sessions do
    Sam.Session.Server.list_sessions()
    |> Enum.map(fn id -> Sam.Session.Server.get_state(id) end)
  end

  defp agent_command(:claude_code, workdir, prompt) do
    cmd = ["claude", "--dangerously-skip-permissions"]
    if prompt && prompt != "", do: cmd ++ [prompt], else: cmd
  end

  defp agent_command(:opencode, _workdir, _prompt), do: ["opencode"]
  defp agent_command(:codex, _workdir, prompt), do: ["codex", prompt || ""]
  defp agent_command(:gemini, _workdir, _prompt), do: ["gemini"]
  defp agent_command(:copilot, _workdir, _prompt), do: ["gh", "copilot"]
  defp agent_command(_, _workdir, _prompt), do: ["/bin/bash", "-l"]

  defp status_label(:running), do: "Working"
  defp status_label(:needs_input), do: "Needs Input"
  defp status_label(:idle), do: "Idle"
  defp status_label(:done), do: "Done"
  defp status_label(:error), do: "Error"
  defp status_label(:starting), do: "Starting"
  defp status_label(_), do: "Unknown"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
  defp format_time(_), do: ""
end
```

- [ ] **Step 3: Create Tron theme CSS**

Create `assets/css/themes.css`:

```css
/* === TRON THEME (default) === */
body.theme-tron, body:not([class*="theme-"]) {
  --bg-primary: #0a0a1a;
  --bg-secondary: #12122a;
  --bg-tertiary: #1a1a35;
  --accent: #00ffff;
  --accent-glow: rgba(0, 255, 255, 0.3);
  --accent-dim: rgba(0, 255, 255, 0.1);
  --text-primary: #e0e0e0;
  --text-secondary: #888888;
  --text-muted: #555555;
  --status-working: #00ff00;
  --status-input: #ffcc00;
  --status-idle: #666666;
  --status-error: #ff4444;
  --status-done: #888888;
  --status-starting: #00aaff;
  --border: rgba(0, 255, 255, 0.15);
  --border-active: rgba(0, 255, 255, 0.5);
  --scanline-display: block;
  --glow-intensity: 1;
}

/* === SYNTHWAVE === */
body.theme-synthwave {
  --bg-primary: #1a0a2e;
  --bg-secondary: #0a0a1a;
  --bg-tertiary: #2a1040;
  --accent: #ff0080;
  --accent-glow: rgba(255, 0, 128, 0.3);
  --accent-dim: rgba(255, 0, 128, 0.1);
  --text-primary: #e0c0ff;
  --text-secondary: #aa88cc;
  --text-muted: #664488;
  --status-working: #00ff00;
  --status-input: #ffcc00;
  --status-idle: #666666;
  --status-error: #ff4444;
  --status-done: #888888;
  --status-starting: #bf80ff;
  --border: rgba(255, 0, 128, 0.2);
  --border-active: rgba(255, 0, 128, 0.6);
  --scanline-display: none;
  --glow-intensity: 1.2;
}

/* === PHOSPHOR === */
body.theme-phosphor {
  --bg-primary: #0a0a0a;
  --bg-secondary: #0d0d0d;
  --bg-tertiary: #141414;
  --accent: #00ff66;
  --accent-glow: rgba(0, 255, 102, 0.3);
  --accent-dim: rgba(0, 255, 102, 0.08);
  --text-primary: #00dd44;
  --text-secondary: #00aa33;
  --text-muted: #006622;
  --status-working: #00ff66;
  --status-input: #ffcc00;
  --status-idle: #004400;
  --status-error: #ff4444;
  --status-done: #006622;
  --status-starting: #00cc55;
  --border: rgba(0, 255, 102, 0.1);
  --border-active: rgba(0, 255, 102, 0.4);
  --scanline-display: block;
  --glow-intensity: 0.8;
}

/* === AMBER === */
body.theme-amber {
  --bg-primary: #0a0800;
  --bg-secondary: #0d0b00;
  --bg-tertiary: #141100;
  --accent: #ffaa00;
  --accent-glow: rgba(255, 170, 0, 0.3);
  --accent-dim: rgba(255, 170, 0, 0.08);
  --text-primary: #ffaa00;
  --text-secondary: #cc8800;
  --text-muted: #664400;
  --status-working: #ffaa00;
  --status-input: #ffcc00;
  --status-idle: #443300;
  --status-error: #ff4444;
  --status-done: #664400;
  --status-starting: #ffcc44;
  --border: rgba(255, 170, 0, 0.1);
  --border-active: rgba(255, 170, 0, 0.4);
  --scanline-display: block;
  --glow-intensity: 0.8;
}
```

- [ ] **Step 4: Create main app CSS**

Add to `assets/css/app.css` (replace default Phoenix styles):

```css
@import "./themes.css";

* { box-sizing: border-box; margin: 0; padding: 0; }

body {
  background: var(--bg-primary);
  color: var(--text-primary);
  font-family: 'Courier New', 'Menlo', 'Monaco', monospace;
  font-size: 13px;
  height: 100vh;
  overflow: hidden;
}

/* Scanline overlay */
body::after {
  content: '';
  position: fixed;
  top: 0; left: 0; right: 0; bottom: 0;
  background: repeating-linear-gradient(
    0deg, transparent, transparent 2px,
    rgba(0,0,0,0.12) 2px, rgba(0,0,0,0.12) 4px
  );
  pointer-events: none;
  z-index: 9999;
  display: var(--scanline-display);
}

/* CRT glow */
body::before {
  content: '';
  position: fixed;
  top: 0; left: 0; right: 0; bottom: 0;
  box-shadow: inset 0 0 80px rgba(0,255,255, calc(0.06 * var(--glow-intensity)));
  pointer-events: none;
  z-index: 9998;
}

.dashboard {
  display: flex;
  flex-direction: column;
  height: 100vh;
}

/* Tab Bar */
.tab-bar {
  display: flex;
  gap: 2px;
  padding: 8px 8px 0;
  border-bottom: 1px solid var(--border);
  background: var(--bg-secondary);
}

.tab {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 8px 14px;
  border: 1px solid var(--border);
  border-bottom: none;
  border-radius: 4px 4px 0 0;
  background: transparent;
  color: var(--text-secondary);
  cursor: pointer;
  font-family: inherit;
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 1px;
  transition: all 0.15s;
}

.tab:hover { background: var(--accent-dim); }

.tab--active {
  background: var(--bg-primary);
  color: var(--text-primary);
  border-bottom: 2px solid var(--accent);
}

.tab--new {
  color: var(--text-muted);
  font-size: 16px;
  padding: 8px 12px;
}

.tab__name { white-space: nowrap; }
.tab__branch { color: var(--text-muted); font-size: 9px; }

/* Status Dots */
.status-dot {
  width: 7px; height: 7px;
  border-radius: 50%;
  display: inline-block;
  flex-shrink: 0;
}
.status-dot--running, .status-dot--working { background: var(--status-working); box-shadow: 0 0 6px var(--status-working); }
.status-dot--needs_input { background: var(--status-input); box-shadow: 0 0 6px var(--status-input); }
.status-dot--idle { background: var(--status-idle); }
.status-dot--done { background: var(--status-done); }
.status-dot--error { background: var(--status-error); box-shadow: 0 0 6px var(--status-error); }
.status-dot--starting { background: var(--status-starting); box-shadow: 0 0 6px var(--status-starting); }

/* Main Panel */
.main-panel {
  display: grid;
  grid-template-columns: 2fr 1fr;
  gap: 16px;
  padding: 16px;
  flex: 1;
  overflow: hidden;
}

.panel-left, .panel-right {
  display: flex;
  flex-direction: column;
  gap: 12px;
  overflow-y: auto;
}

/* Status Badge */
.status-badge {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 2px;
  color: var(--accent);
}

.task-description {
  font-size: 14px;
  color: var(--text-primary);
  font-weight: normal;
}

/* Activity Feed */
.activity-feed {
  flex: 1;
  overflow-y: auto;
  border: 1px solid var(--border);
  padding: 10px;
  background: var(--bg-secondary);
}

.activity-entry {
  padding: 6px 0;
  border-bottom: 1px solid var(--border);
}

.activity-time {
  color: var(--text-muted);
  font-size: 10px;
  margin-right: 8px;
}

.activity-text {
  color: var(--text-secondary);
  font-size: 12px;
}

.activity-empty, .agents-empty {
  color: var(--text-muted);
  font-style: italic;
  padding: 20px;
  text-align: center;
}

/* Section Headers */
.section-header {
  color: var(--accent);
  font-size: 9px;
  text-transform: uppercase;
  letter-spacing: 3px;
}

/* Agent Cards */
.agent-list { display: flex; flex-direction: column; gap: 6px; }

.agent-card {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 8px 10px;
  border: 1px solid var(--border);
  background: var(--bg-secondary);
}

/* Input Bar */
.input-bar {
  border: 1px solid var(--status-input);
  padding: 10px;
  background: rgba(255, 204, 0, 0.05);
}

.quick-actions {
  display: flex;
  gap: 8px;
  margin-bottom: 8px;
}

.btn-quick {
  padding: 4px 16px;
  border: 1px solid var(--accent);
  background: transparent;
  color: var(--accent);
  font-family: inherit;
  cursor: pointer;
  text-transform: uppercase;
  font-size: 10px;
  letter-spacing: 1px;
}

.btn-quick:hover { background: var(--accent-dim); }

.input-form {
  display: flex;
  gap: 8px;
}

.input-field {
  flex: 1;
  padding: 6px 10px;
  background: var(--bg-primary);
  border: 1px solid var(--border);
  color: var(--text-primary);
  font-family: inherit;
  font-size: 12px;
}

.btn-send, .btn-terminal, .btn-create {
  padding: 6px 16px;
  border: 1px solid var(--accent);
  background: transparent;
  color: var(--accent);
  font-family: inherit;
  cursor: pointer;
  text-transform: uppercase;
  font-size: 10px;
  letter-spacing: 1px;
}

.btn-send:hover, .btn-terminal:hover, .btn-create:hover {
  background: var(--accent-dim);
}

/* Terminal Container */
#terminal-container {
  position: absolute;
  top: 50px;
  left: 0; right: 0; bottom: 0;
  background: var(--bg-primary);
  z-index: 100;
}

#terminal {
  width: 100%;
  height: 100%;
}

/* Dialog */
.dialog-overlay {
  position: fixed;
  top: 0; left: 0; right: 0; bottom: 0;
  background: rgba(0,0,0,0.7);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 200;
}

.dialog {
  background: var(--bg-secondary);
  border: 1px solid var(--accent);
  padding: 24px;
  min-width: 400px;
}

.dialog h3 {
  color: var(--accent);
  text-transform: uppercase;
  letter-spacing: 2px;
  font-size: 12px;
  margin-bottom: 16px;
}

.dialog label {
  display: block;
  color: var(--text-secondary);
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 1px;
  margin: 12px 0 4px;
}

.dialog select, .dialog input, .dialog textarea {
  width: 100%;
  padding: 8px;
  background: var(--bg-primary);
  border: 1px solid var(--border);
  color: var(--text-primary);
  font-family: inherit;
  font-size: 12px;
}

.dialog .btn-create {
  margin-top: 16px;
  width: 100%;
  padding: 10px;
}

/* Empty State */
.empty-state {
  display: flex;
  align-items: center;
  justify-content: center;
  flex: 1;
  color: var(--text-muted);
}

/* Theme Switcher (keyboard shortcut hint) */
.theme-switcher {
  position: fixed;
  bottom: 8px;
  right: 8px;
  color: var(--text-muted);
  font-size: 9px;
}
```

- [ ] **Step 5: Update root layout**

Modify `lib/sam_web/layouts/root.html.heex` to add theme class and import:

Add `class="theme-tron"` to the `<body>` tag. The LiveView will handle theme switching via JS hooks.

- [ ] **Step 6: Verify the dashboard renders**

```bash
mix phx.server
```

Visit `http://localhost:4000` — should see empty dashboard with Tron theme (dark background, cyan accents, tab bar with "+" button). Stop with Ctrl+C.

- [ ] **Step 7: Commit**

```bash
git add lib/sam_web/live/dashboard_live.ex lib/sam_web/router.ex assets/css/themes.css assets/css/app.css lib/sam_web/layouts/root.html.heex
git commit -m "feat: add Dashboard LiveView with Tron theme and tab bar"
```

### Task 9: Terminal Channel + xterm.js

**Files:**
- Create: `lib/sam_web/channels/terminal_channel.ex`
- Modify: `lib/sam_web/channels/user_socket.ex` — add channel route
- Create: `assets/js/terminal.js`
- Modify: `assets/js/app.js` — import terminal hook
- Create: `assets/package.json` — add xterm deps

- [ ] **Step 1: Install xterm.js via npm**

```bash
cd /Users/johrt/Code/secret-agent-man/assets
npm init -y
npm install @xterm/xterm @xterm/addon-fit @xterm/addon-webgl
cd ..
```

- [ ] **Step 2: Create Terminal Channel**

Create `lib/sam_web/channels/terminal_channel.ex`:

```elixir
defmodule SamWeb.TerminalChannel do
  use Phoenix.Channel

  @impl true
  def join("terminal:" <> session_id, _payload, socket) do
    # Verify session exists
    case Registry.lookup(Sam.ProcessRegistry, session_id) do
      [{_pid, _}] ->
        # Subscribe to PTY output for this session
        Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")
        {:ok, assign(socket, session_id: session_id)}

      [] ->
        {:error, %{reason: "session not found"}}
    end
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    Sam.Session.Server.send_input(socket.assigns.session_id, data)
    {:noreply, socket}
  end

  @impl true
  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    Sam.Session.Server.resize(socket.assigns.session_id, cols, rows)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_output, _session_id, data}, socket) do
    push(socket, "output", %{data: Base.encode64(data)})
    {:noreply, socket}
  end

  # Ignore other PubSub messages (parser events, summaries, etc.)
  @impl true
  def handle_info(_, socket), do: {:noreply, socket}
end
```

- [ ] **Step 3: Add channel route**

In `lib/sam_web/channels/user_socket.ex`:

```elixir
channel "terminal:*", SamWeb.TerminalChannel
```

- [ ] **Step 4: Create terminal.js hook**

Create `assets/js/terminal.js`:

```javascript
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebglAddon } from '@xterm/addon-webgl'

const TerminalHook = {
  mounted() {
    const sessionId = this.el.dataset.sessionId
    const container = this.el.querySelector('#terminal')

    // Create terminal
    this.term = new Terminal({
      theme: {
        background: '#0a0a1a',
        foreground: '#e0e0e0',
        cursor: '#00ffff',
        cursorAccent: '#0a0a1a',
        selectionBackground: 'rgba(0, 255, 255, 0.3)',
      },
      fontFamily: "'Courier New', 'Menlo', monospace",
      fontSize: 13,
      cursorBlink: true,
    })

    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.open(container)

    try {
      this.term.loadAddon(new WebglAddon())
    } catch (e) {
      console.warn('WebGL addon not available, using canvas renderer')
    }

    this.fitAddon.fit()

    // Connect to Phoenix channel — import Socket from phoenix (bundled by esbuild)
    import { Socket } from 'phoenix'
    const socket = new Socket('/socket', { params: {} })
    socket.connect()

    this.channel = socket.channel(`terminal:${sessionId}`, {})
    this.channel.join()
      .receive('ok', () => console.log(`Connected to terminal:${sessionId}`))
      .receive('error', (resp) => console.error('Failed to join', resp))

    // Terminal input → channel
    this.term.onData((data) => {
      this.channel.push('input', { data })
    })

    // Channel output → terminal
    this.channel.on('output', ({ data }) => {
      const bytes = atob(data)
      this.term.write(bytes)
    })

    // Handle resize
    this.term.onResize(({ cols, rows }) => {
      this.channel.push('resize', { cols, rows })
    })

    // Fit on window resize
    this._resizeHandler = () => this.fitAddon.fit()
    window.addEventListener('resize', this._resizeHandler)

    // Escape to close
    this._keyHandler = (e) => {
      if (e.key === 'Escape') {
        this.pushEvent('toggle_terminal', {})
      }
    }
    document.addEventListener('keydown', this._keyHandler)
  },

  destroyed() {
    if (this.channel) this.channel.leave()
    if (this.term) this.term.dispose()
    if (this._resizeHandler) window.removeEventListener('resize', this._resizeHandler)
    if (this._keyHandler) document.removeEventListener('keydown', this._keyHandler)
  }
}

export default TerminalHook
```

- [ ] **Step 5: Import hook in app.js**

In `assets/js/app.js`, add:

```javascript
import TerminalHook from './terminal'

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { Terminal: TerminalHook },
  // ... existing config
})
```

- [ ] **Step 6: Test terminal embed**

```bash
mix phx.server
```

1. Open `http://localhost:4000`
2. Click "+" to create a new session (use `/bin/bash` or Claude Code)
3. Click "Open Terminal"
4. Should see full interactive terminal
5. Type a command — should work
6. Press Esc to return to structured view

- [ ] **Step 7: Commit**

```bash
git add lib/sam_web/channels/ assets/js/terminal.js assets/js/app.js assets/package.json assets/package-lock.json
git commit -m "feat: add xterm.js terminal embed via Phoenix Channel"
```

### Task 10: Hook Controller

**Files:**
- Create: `lib/sam_web/controllers/hook_controller.ex`
- Modify: `lib/sam_web/router.ex` — add API route

- [ ] **Step 1: Create HookController**

Create `lib/sam_web/controllers/hook_controller.ex`:

```elixir
defmodule SamWeb.HookController do
  use SamWeb, :controller

  def create(conn, params) do
    session_id = params["session_id"]
    event = params["event"]

    case Sam.Session.Registry.lookup(session_id) do
      {:ok, _pid} ->
        # Route to the session's parser
        Sam.Session.Server.push_hook_event(session_id, params)
        json(conn, %{status: "ok"})

      :error ->
        conn
        |> put_status(404)
        |> json(%{error: "session not found"})
    end
  end
end
```

- [ ] **Step 2: Add API route**

In `lib/sam_web/router.ex`:

```elixir
scope "/api", SamWeb do
  pipe_through :api
  post "/hooks", HookController, :create
end
```

- [ ] **Step 3: Add push_hook_event to Session.Server**

```elixir
def push_hook_event(session_id, event) do
  GenServer.cast(via(session_id), {:hook_event, event})
end
```

And the handler:

```elixir
@impl true
def handle_cast({:hook_event, event}, state) do
  if state.parser_pid do
    Sam.Session.Parser.push_hook_event(state.parser_pid, event)
  end
  {:noreply, state}
end
```

- [ ] **Step 4: Test with curl**

```bash
# Start server
mix phx.server

# In another terminal, create a session first via the UI, then:
curl -s -X POST http://localhost:4000/api/hooks \
  -H "Content-Type: application/json" \
  -d '{"event":"tool_call","tool":"Edit","file":"test.ts","session_id":"sam-1"}'
```

Expected: 200 OK.

- [ ] **Step 5: Commit**

```bash
git add lib/sam_web/controllers/hook_controller.ex lib/sam_web/router.ex lib/sam/session/server.ex
git commit -m "feat: add Hook controller for Claude Code event ingestion"
```

---

## Phase 4: Agent Adapters

### Task 11: Agent Behaviour + Claude Code Adapter

**Files:**
- Create: `lib/sam/agents/behaviour.ex`
- Create: `lib/sam/agents/claude_code.ex`

- [ ] **Step 1: Define the Agent behaviour**

Create `lib/sam/agents/behaviour.ex`:

```elixir
defmodule Sam.Agents.Behaviour do
  @moduledoc "Behaviour that all agent adapters implement."

  @callback spawn_command(workdir :: String.t(), prompt :: String.t() | nil) :: [String.t()]
  @callback detect_running?() :: boolean()
  @callback parse_tier() :: :hooks | :stream | :llm
end
```

- [ ] **Step 2: Implement Claude Code adapter**

Create `lib/sam/agents/claude_code.ex`:

```elixir
defmodule Sam.Agents.ClaudeCode do
  @behaviour Sam.Agents.Behaviour

  @impl true
  def spawn_command(workdir, prompt) do
    base = ["claude", "--dangerously-skip-permissions"]
    cmd = if prompt && prompt != "", do: base ++ [prompt], else: base
    cmd
  end

  @impl true
  def detect_running? do
    case System.cmd("pgrep", ["-f", "claude"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  @impl true
  def parse_tier, do: :hooks
end
```

- [ ] **Step 3: Update DashboardLive to use adapters**

Replace the `agent_command/3` function in `dashboard_live.ex`:

```elixir
defp agent_command(agent_type, workdir, prompt) do
  adapter = agent_adapter(agent_type)
  adapter.spawn_command(workdir, prompt)
end

defp agent_adapter(:claude_code), do: Sam.Agents.ClaudeCode
defp agent_adapter(_), do: Sam.Agents.Generic
```

Create a generic fallback `lib/sam/agents/generic.ex`:

```elixir
defmodule Sam.Agents.Generic do
  @behaviour Sam.Agents.Behaviour

  @impl true
  def spawn_command(_workdir, _prompt), do: ["/bin/bash", "-l"]

  @impl true
  def detect_running?, do: false

  @impl true
  def parse_tier, do: :llm
end
```

- [ ] **Step 4: Commit**

```bash
git add lib/sam/agents/
git commit -m "feat: add Agent behaviour and Claude Code adapter"
```

---

## Phase 5: Theme Switching + Polish

### Task 12: Client-Side Theme Switching

**Files:**
- Create: `assets/js/theme.js`
- Modify: `assets/js/app.js`
- Modify: `lib/sam_web/live/dashboard_live.ex` — add theme picker

- [ ] **Step 1: Create theme.js**

Create `assets/js/theme.js`:

```javascript
const THEMES = ['tron', 'synthwave', 'phosphor', 'amber']
const STORAGE_KEY = 'sam-theme'

export function initTheme() {
  const saved = localStorage.getItem(STORAGE_KEY) || 'tron'
  applyTheme(saved)
}

export function cycleTheme() {
  const current = getCurrentTheme()
  const idx = THEMES.indexOf(current)
  const next = THEMES[(idx + 1) % THEMES.length]
  applyTheme(next)
  return next
}

export function applyTheme(name) {
  document.body.className = `theme-${name}`
  localStorage.setItem(STORAGE_KEY, name)
}

export function getCurrentTheme() {
  return localStorage.getItem(STORAGE_KEY) || 'tron'
}

// Keyboard shortcut: Ctrl+T to cycle themes
document.addEventListener('keydown', (e) => {
  if (e.ctrlKey && e.key === 't') {
    e.preventDefault()
    const theme = cycleTheme()
    console.log(`Theme: ${theme}`)
  }
})
```

- [ ] **Step 2: Import in app.js**

```javascript
import { initTheme } from './theme'
initTheme()
```

- [ ] **Step 3: Add theme indicator to dashboard**

Add to the bottom of the DashboardLive render:

```html
<div class="theme-switcher">Ctrl+T to switch theme</div>
```

- [ ] **Step 4: Test all 4 themes**

```bash
mix phx.server
```

Visit `http://localhost:4000`, press Ctrl+T multiple times. Each theme should apply instantly. Verify:
- Tron: cyan on dark
- Synthwave: pink/purple neon
- Phosphor: green on black
- Amber: amber monochrome

- [ ] **Step 5: Commit**

```bash
git add assets/js/theme.js assets/js/app.js lib/sam_web/live/dashboard_live.ex
git commit -m "feat: add client-side theme switching with 4 built-in themes"
```

---

## Phase 6: Integration + Verification

### Task 13: End-to-End Integration Test

**Files:**
- Create: `test/sam_web/live/dashboard_live_test.exs`

- [ ] **Step 1: Write integration test**

Create `test/sam_web/live/dashboard_live_test.exs`:

```elixir
defmodule SamWeb.DashboardLiveTest do
  use SamWeb.ConnCase
  import Phoenix.LiveViewTest

  test "renders empty dashboard", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "+"
    assert html =~ "No session selected"
  end

  test "creates a bash session and shows it in tab bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # Open new session dialog
    view |> element(".tab--new") |> render_click()
    assert render(view) =~ "New Session"

    # Submit form — use generic (bash) to avoid requiring claude binary
    view
    |> form("form", %{
      agent_type: "generic",
      workdir: System.tmp_dir!(),
      prompt: ""
    })
    |> render_submit()

    # Session should appear in tab bar
    html = render(view)
    refute html =~ "No session selected"
  end
end
```

- [ ] **Step 2: Run tests**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 3: Manual acceptance verification**

Run through the acceptance checks from the spec:

1. Launch `mix phx.server`
2. Create a bash session → verify it appears in tab bar
3. Click the session tab → verify activity feed shows
4. Open terminal → type commands → verify they work
5. Press Ctrl+T → verify themes switch
6. Create 2 more sessions → verify tabs show independently
7. Close sessions → verify status updates

- [ ] **Step 4: Commit**

```bash
git add test/sam_web/live/dashboard_live_test.exs
git commit -m "test: add dashboard LiveView integration tests"
```

### Task 14: Persistence (DETS)

**Files:**
- Create: `lib/sam/persistence.ex`

- [ ] **Step 1: Implement Persistence module**

Create `lib/sam/persistence.ex`:

```elixir
defmodule Sam.Persistence do
  use GenServer
  require Logger

  @flush_interval_ms 30_000
  @dets_file 'sam_sessions.dets'

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    dets_path = Path.join(data_dir(), to_string(@dets_file)) |> to_charlist()
    {:ok, table} = :dets.open_file(:sam_persistence, [file: dets_path, type: :set])
    schedule_flush()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:flush, state) do
    flush_sessions(state.table)
    schedule_flush()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    flush_sessions(state.table)
    :dets.close(state.table)
  end

  defp flush_sessions(table) do
    sessions = Sam.Session.Registry.all()
    Enum.each(sessions, fn {id, _pid} ->
      try do
        state = Sam.Session.Server.get_state(id)
        serializable = %{
          session_id: state.session_id,
          name: state.name,
          status: state.status,
          agent_type: state.agent_type,
          activity: Enum.take(state.activity, 50)
        }
        :dets.insert(table, {id, serializable})
      rescue
        _ -> :ok
      end
    end)
    Logger.debug("Flushed #{length(sessions)} sessions to DETS")
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp data_dir do
    dir = Path.join(System.user_home!(), ".config/secret-agent-man/data")
    File.mkdir_p!(dir)
    dir
  end
end
```

- [ ] **Step 2: Add to Application supervisor**

Add `Sam.Persistence` to the children list in `lib/sam/application.ex`.

- [ ] **Step 3: Commit**

```bash
git add lib/sam/persistence.ex lib/sam/application.ex
git commit -m "feat: add DETS persistence for session state"
```

### Task 15: Configuration + mix setup

**Files:**
- Modify: `config/runtime.exs`
- Modify: `mix.exs` — add aliases

- [ ] **Step 1: Add runtime config**

In `config/runtime.exs`:

```elixir
config :sam,
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY")
```

- [ ] **Step 2: Add mix setup alias**

In `mix.exs` aliases:

```elixir
defp aliases do
  [
    setup: ["deps.get", "cmd make zig_build", "cmd cd assets && npm install", "assets.setup"],
    # ... existing aliases
  ]
end
```

- [ ] **Step 3: Add .gitkeep for priv/native**

```bash
touch priv/native/.gitkeep
git add priv/native/.gitkeep
```

- [ ] **Step 4: Test full setup from scratch**

```bash
cd /Users/johrt/Code/secret-agent-man
mix setup
mix phx.server
```

Verify everything starts cleanly.

- [ ] **Step 5: Commit**

```bash
git add config/runtime.exs mix.exs priv/native/.gitkeep
git commit -m "feat: add runtime config and mix setup alias"
```

---

### Task 16: Health & Debug API Endpoints

**Files:**
- Create: `lib/sam_web/controllers/api_controller.ex`
- Modify: `lib/sam_web/router.ex`

- [ ] **Step 1: Create ApiController**

```elixir
defmodule SamWeb.ApiController do
  use SamWeb, :controller

  def health(conn, _params) do
    sessions = Sam.Session.Server.list_sessions()
    json(conn, %{
      status: "ok",
      session_count: length(sessions),
      uptime_seconds: System.monotonic_time(:second)
    })
  end

  def sessions(conn, _params) do
    sessions = Sam.Session.Server.list_sessions()
    |> Enum.map(fn id ->
      state = Sam.Session.Server.get_state(id)
      %{
        session_id: state.session_id,
        name: state.name,
        status: state.status,
        agent_type: state.agent_type,
        activity_count: length(state.activity)
      }
    end)
    json(conn, %{sessions: sessions})
  end
end
```

- [ ] **Step 2: Add routes**

In `lib/sam_web/router.ex`, in the API scope:

```elixir
get "/health", ApiController, :health
get "/sessions", ApiController, :sessions
```

- [ ] **Step 3: Test**

```bash
curl http://localhost:4000/api/health
# {"status":"ok","session_count":0,"uptime_seconds":...}

curl http://localhost:4000/api/sessions
# {"sessions":[]}
```

- [ ] **Step 4: Commit**

```bash
git add lib/sam_web/controllers/api_controller.ex lib/sam_web/router.ex
git commit -m "feat: add health and sessions debug API endpoints"
```

### Task 17: Claude Code Hook Auto-Registration

**Files:**
- Create: `lib/sam/hooks/claude_code_hooks.ex`

- [ ] **Step 1: Implement hook registration**

```elixir
defmodule Sam.Hooks.ClaudeCodeHooks do
  @moduledoc "Auto-registers SAM hooks in Claude Code settings."

  @settings_path Path.join(System.user_home!(), ".claude/settings.json")

  def check_and_prompt do
    case File.read(@settings_path) do
      {:ok, content} ->
        settings = Jason.decode!(content)
        if has_sam_hooks?(settings) do
          :already_registered
        else
          :needs_registration
        end

      {:error, :enoent} ->
        :no_settings_file

      {:error, _} ->
        :error
    end
  end

  def register_hooks! do
    content = case File.read(@settings_path) do
      {:ok, c} -> c
      {:error, :enoent} -> "{}"
    end

    settings = Jason.decode!(content)
    hooks = Map.get(settings, "hooks", %{})

    sam_hook = %{
      "type" => "command",
      "command" => "curl -s -X POST http://localhost:4000/api/hooks -H 'Content-Type: application/json' -d '{\"event\":\"$EVENT\",\"session_id\":\"$SESSION_ID\"}'"
    }

    # Add to post-tool-use hooks
    post_tool = Map.get(hooks, "postToolUse", [])
    updated_hooks = Map.put(hooks, "postToolUse", post_tool ++ [sam_hook])
    updated_settings = Map.put(settings, "hooks", updated_hooks)

    File.write!(@settings_path, Jason.encode!(updated_settings, pretty: true))
    :ok
  end

  defp has_sam_hooks?(settings) do
    settings
    |> Map.get("hooks", %{})
    |> Enum.any?(fn {_key, hooks} ->
      Enum.any?(List.wrap(hooks), fn hook ->
        is_map(hook) && String.contains?(Map.get(hook, "command", ""), "localhost:4000/api/hooks")
      end)
    end)
  end
end
```

- [ ] **Step 2: Prompt on first session creation**

In `DashboardLive`, when creating a Claude Code session, check:

```elixir
if agent_type == :claude_code do
  case Sam.Hooks.ClaudeCodeHooks.check_and_prompt() do
    :needs_registration ->
      # Show a flash/banner asking user to approve hook registration
      socket = put_flash(socket, :info, "SAM can register hooks in Claude Code for better status tracking. Approve?")
    _ -> :ok
  end
end
```

- [ ] **Step 3: Commit**

```bash
git add lib/sam/hooks/claude_code_hooks.ex
git commit -m "feat: add Claude Code hook auto-registration"
```

---

## Phase 7: Packaging (future, not for v1 launch)

> Tasks 16-17 are for when you're ready to distribute. Skip during initial development.

### Task 16: Burrito Release Config

_Deferred — configure Burrito for standalone binary packaging when ready to release._

### Task 17: Homebrew Formula

_Deferred — create Homebrew tap when first release is ready._
