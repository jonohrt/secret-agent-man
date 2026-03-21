# Design: Notifications + Directory Picker + Journal Finder

**Date:** 2026-03-20
**Branch:** feature/blue-steel-ui
**Status:** Approved

Three features designed as a coherent batch. All build on existing infrastructure with minimal new dependencies.

---

## Feature 1: Sound/Visual Notifications

### Purpose

Alert users when agent sessions need attention while they're not watching the dashboard. Triggers on actionable status transitions only — not every state change.

### Trigger Events

| Status | Notification | Sound |
|--------|-------------|-------|
| `needs_input` | Browser notification + toast | Chime |
| `done` | Browser notification + toast | None |
| `error` | Browser notification + toast | Chime |

### Architecture

```
Server (status change) → PubSub "sessions:ui"
  → DashboardLive.handle_info(:session_update)
    → push_event("notify", %{status, session_name, session_id})
      → JS Hook "Notifications"
        → Browser Notification API
        → Web Audio API chime
        → Toast DOM overlay
```

### Components

**Server-side (DashboardLive):**
- Detect transitions to `:needs_input`, `:done`, `:error` in `handle_info/2`
- Compare previous status to new status — only fire on *transition*, not repeat
- `push_event("notify", %{status: status, session_name: name, session_id: id})`

**Client-side (Notifications JS Hook):**
- Mounted on dashboard root element
- Requests `Notification.requestPermission()` on first mount
- Handles `"notify"` push event:
  - Creates `new Notification(title, {body, icon})` when tab is not focused
  - Synthesizes chime via Web Audio API (~200ms tone) for `needs_input` and `error`
  - Inserts toast DOM element in top-right corner
- Toast auto-dismisses after 5s, click-to-dismiss
- Sound mute toggle persisted to `localStorage`
- Sound OFF by default — user opts in via toggle
- If `Notification.requestPermission()` denied: toasts + sound still work, browser notifications silently skipped

**Toast UI:**
- Fixed position top-right overlay
- Styled to match CRT theme (dark surface, colored border matching status)
- Shows: status dot + session name + status message
- Stacks vertically when multiple toasts active
- Dismiss button (×)

**Sound:**
- Web Audio API oscillator — no audio file dependency
- Short sine wave tone, ~200ms, gentle volume
- Mute/unmute toggle button in top nav bar
- Mute state persisted to `localStorage("sam-sound-muted")`

### No New Dependencies

Entirely built on existing LiveView push events + browser APIs.

---

## Feature 2: Directory Picker with Default Path

### Purpose

Replace the plain text workdir input in the "New Operation" modal with a browsable directory picker. Optimized for umbrella projects — set a base path once, then quick-pick subdirectories.

### UX Flow

1. **On modal open:** Text input pre-filled with default base path. MRU chips shown above.
2. **Click MRU chip:** Instantly sets path. No tree needed.
3. **Click Browse:** Expands directory tree rooted at base path. Click folders to navigate, click to select.
4. **Manual typing still works:** Text input remains editable for power users.
5. **On session create:** Selected path added to MRU list (capped at 5, deduped).

### Components

**DirectoryPicker (LiveComponent):**
- `lib/sam_web/components/directory_picker.ex`
- Attrs: `base_path` (from settings), `mru_paths` (list of recent), `selected_path` (current value)
- Events: `browse_toggle`, `navigate` (dir click), `select_dir`, `select_mru`
- Lists directories only via `File.ls/1` + `File.dir?/1`
- Hides dotfiles/dotdirs by default
- Sorts alphabetically
- Shows relative paths from base (e.g., `apps/api` not full absolute path)
- Breadcrumb navigation at top of tree

**Settings Persistence (DETS):**
- New DETS table `sam_settings` (separate from session data table `sam_sessions`)
- Key-value store: `{:default_workdir, path}`, `{:mru_workdirs, [paths]}`
- Settings module: `Sam.Settings` — GenServer wrapping DETS open/read/write
- File location: `~/.config/secret-agent-man/data/sam_settings`
- Settings UI: minimal — gear icon in top nav opens modal with base path input

### Behavior Details

- Base path expansion: `~` expanded to `System.user_home!()`
- If base path doesn't exist, text input shown with validation error
- If `File.ls/1` fails (permissions), show error inline, don't crash
- Tree depth: start at base, navigate into children on click, parent (..) link to go up
- Selected directory highlighted with green accent

### No New Dependencies

Server-side file listing, LiveComponent, DETS persistence — all existing tools.

---

## Feature 3: JSONL File Correlation via Filesystem Watcher

### Purpose

Replace the flaky birthtime/mtime heuristic in TranscriptWatcher with deterministic filesystem event-based JSONL file discovery. Fixes the known issue where TranscriptWatcher locks onto the wrong file when multiple sessions run concurrently.

### Architecture

```
GroupSupervisor (rest_for_one)
  ├─ Server
  ├─ Summarizer
  ├─ Parser
  ├─ TranscriptWatcher  ← receives {:journal_found, path}
  ├─ JournalFinder       ← NEW (fsevents watcher)
  └─ PTY
```

JournalFinder starts *before* PTY in the supervision tree. It watches the Claude projects directory. When PTY spawns Claude Code, the first new `.jsonl` file created is deterministically ours.

**Restart strategy:** JournalFinder uses `:temporary` restart — if it crashes, it does not restart and does not take down PTY via `rest_for_one`. JSONL correlation is a nice-to-have; killing the agent session over a watcher crash is unacceptable. If JournalFinder dies, TranscriptWatcher simply stays in `:waiting` state (no status indicators, but session works fine).

### Process Lifecycle

1. GroupSupervisor starts JournalFinder (before PTY)
2. JournalFinder computes watch dir: `~/.claude/projects/<encoded-workdir>/`
3. JournalFinder starts `FileSystem` watcher on that directory
4. JournalFinder records `start_time = System.monotonic_time()`
5. PTY spawns Claude Code process
6. Claude Code creates `<uuid>.jsonl`
7. FileSystem fires `:created` event for the `.jsonl` file
8. JournalFinder sends `{:journal_found, path}` to TranscriptWatcher (by name)
9. JournalFinder stops its FileSystem watcher (job done, stays alive for supervision)
10. TranscriptWatcher transitions from `:waiting` to `:watching` state

### Components

**JournalFinder (GenServer):**
- `lib/sam/session/journal_finder.ex`
- Init args: `session_id`, `workdir`
- Computes encoded watch dir (reuses existing `encode_workdir/1` logic)
- Creates watch dir if it doesn't exist (`File.mkdir_p!/1`)
- Starts `FileSystem` watcher process linked to self
- Filters events: only `.jsonl` extension + `:created` type
- Sends `{:journal_found, path}` to TranscriptWatcher via Registry name (TranscriptWatcher is guaranteed started before JournalFinder in supervision order; if lookup fails, log and stay idle)
- 60s timeout: logs warning, stays idle (no fallback to mtime — graceful degradation over flaky heuristic)
- Handles PTY exit gracefully (rest_for_one means PTY crash doesn't kill it)
- Restart: `:temporary` — crash doesn't cascade to PTY

**TranscriptWatcher Changes:**
- Remove: birthtime polling logic, mtime fallback timer, `find_journal_file/1`
- Add: starts in `:waiting` state (no file path yet)
- Add: `handle_info({:journal_found, path}, state)` — transitions to `:watching`
- Existing JSONL parsing logic (read new bytes, parse records) unchanged
- Simpler init: no polling timer on startup

### Watch Directory Encoding

Claude Code path: `~/.claude/projects/<encoded-workdir>/<uuid>.jsonl`

Encoding rule: `/Users/johrt/Code/my-project` → `-Users-johrt-Code-my-project`

JournalFinder reuses TranscriptWatcher's existing encoding function (extract to shared module or call directly).

### Edge Cases

- **Watch dir doesn't exist:** JournalFinder creates it with `File.mkdir_p!/1`
- **Multiple `.jsonl` created rapidly:** First one wins (Claude Code creates one per session)
- **PTY exits before file found:** JournalFinder stays alive (above PTY in tree), handles timeout gracefully
- **FileSystem watcher crashes:** JournalFinder dies (`:temporary` — no restart), TranscriptWatcher stays in `:waiting` — session continues without status indicators

### New Dependency

```elixir
{:file_system, "~> 1.0"}
```

Uses `fsevent_watch` on macOS (native fsevents), `inotifywait` on Linux.

---

## Testing Strategy (TDD)

All features follow TDD — failing test first, then implementation.

### Notifications Tests
- **Unit:** DashboardLive pushes notify event on status transition (needs_input, done, error)
- **Unit:** No duplicate notification when status unchanged
- **E2E:** Wallaby test verifies toast appears when session enters needs_input

### Directory Picker Tests
- **Unit:** DirectoryPicker component renders with base path and MRU chips
- **Unit:** Navigate event updates displayed directory listing
- **Unit:** Select event updates selected path
- **Unit:** MRU list updates on session create (capped at 5, deduped)
- **Unit:** Settings persistence (DETS round-trip for default_workdir and mru_workdirs)

### JournalFinder Tests
- **Unit:** JournalFinder detects new .jsonl file in watched directory
- **Unit:** JournalFinder ignores non-.jsonl files
- **Unit:** JournalFinder sends {:journal_found, path} to TranscriptWatcher
- **Unit:** Timeout logs warning and stays idle (no journal found)
- **Integration:** Full session start → JournalFinder → TranscriptWatcher receives path
