# Design: `./bin/setup` Bootstrap Script

## Purpose

A single shell script that takes a fresh clone from zero to running. Checks system dependencies, offers to install missing ones, verifies versions, then runs the Elixir project setup.

## Dependencies

| Dependency | Check command | Min version | macOS (brew) | Linux (apt) | Linux (dnf) |
|---|---|---|---|---|---|
| Erlang/OTP | `erl -eval '...' -noshell` | >= 25 | `brew install erlang` | `apt install erlang` | `dnf install erlang` |
| Elixir | `elixir --version` | >= 1.15 | `brew install elixir` | `apt install elixir` | `dnf install elixir` |
| Zig | `zig version` | existence only | `brew install zig` | `snap install zig` | `dnf install zig` |
| Node.js | `node --version` | existence only | `brew install node` | `apt install nodejs` | `dnf install nodejs` |
| chromedriver | `chromedriver --version` | existence only | `brew install chromedriver` | `apt install chromium-chromedriver` | `dnf install chromedriver` |

## Flow

1. Detect OS (macOS / Linux) and package manager (brew / apt / dnf)
2. For each dependency in order:
   - Check if binary exists
   - If exists and has a min version requirement, check version
   - If missing or too old: print install/upgrade command, prompt y/n
   - Install if user agrees, skip if not
3. Chromedriver is checked last and marked optional (only for E2E tests)
4. If any critical dep (Erlang, Elixir, Zig, Node) was skipped, warn and exit
5. Run `mix local.hex --force --if-missing`
6. Run `mix local.rebar --force --if-missing`
7. Run `mix setup` (deps.get, zig build, assets.setup, assets.build)
8. Print success summary with instructions to run `mix phx.server`

## Version Checking

- **Elixir**: Parse `elixir --version` output (e.g. "Elixir 1.16.0"), compare major.minor >= 1.15
- **Erlang/OTP**: Parse `erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell`, compare >= 25
- **Zig, Node, chromedriver**: Existence check only

If a dep exists but is too old, treat it the same as missing — show upgrade command, ask y/n.

## Design Decisions

- **Shell script, not Mix task**: Users won't have Elixir installed yet
- **macOS + Linux**: Detect platform, use appropriate package manager
- **Check + offer**: Show install command, ask y/n before each install (not silent)
- **Version checks for Elixir/OTP only**: These are most likely to cause compatibility issues
- **Chromedriver is optional**: Don't block setup if skipped

## File Location

`./bin/setup` — executable bash script at project root.
