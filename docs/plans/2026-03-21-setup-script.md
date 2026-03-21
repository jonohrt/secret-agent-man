# `./bin/setup` Bootstrap Script Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a shell script that bootstraps the project from a fresh clone — checks system deps, offers to install missing ones, validates versions, then runs the Elixir project setup.

**Architecture:** Single bash script at `./bin/setup`. Detects OS/package manager, iterates through a dependency list (Erlang, Elixir, Zig, Node, chromedriver), checks existence + version where applicable, prompts y/n to install missing ones, then delegates to `mix setup` for project-level setup.

**Tech Stack:** Bash, Homebrew (macOS), apt/dnf (Linux)

**Design doc:** `docs/plans/2026-03-21-setup-script-design.md`

---

### Task 1: Create `bin/setup` with platform detection and helpers

**Files:**
- Create: `bin/setup`

**Step 1: Create the script with shebang, color helpers, platform detection, and prompt function**

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}==>${NC} ${BOLD}$1${NC}"; }
ok()    { echo -e "${GREEN}  ✓${NC} $1"; }
warn()  { echo -e "${YELLOW}  !${NC} $1"; }
fail()  { echo -e "${RED}  ✗${NC} $1"; }

# Prompt y/n, default yes
ask() {
  local prompt="$1"
  local reply
  echo -en "${CYAN}  ?${NC} ${prompt} [Y/n] "
  read -r reply
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# --- Platform detection ---
detect_platform() {
  case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux)  OS="linux" ;;
    *)      fail "Unsupported OS: $(uname -s)"; exit 1 ;;
  esac

  if [[ "$OS" == "macos" ]]; then
    if command -v brew &>/dev/null; then
      PKG="brew"
    else
      fail "Homebrew not found. Install it from https://brew.sh"
      exit 1
    fi
  elif [[ "$OS" == "linux" ]]; then
    if command -v apt-get &>/dev/null; then
      PKG="apt"
    elif command -v dnf &>/dev/null; then
      PKG="dnf"
    else
      fail "No supported package manager found (need apt or dnf)"
      exit 1
    fi
  fi
}

MISSING_CRITICAL=0

detect_platform
info "Detected: $OS ($PKG)"
echo ""
```

**Step 2: Make it executable and test platform detection**

Run:
```bash
chmod +x bin/setup
bin/setup
```
Expected: Prints "Detected: macos (brew)" and exits cleanly.

**Step 3: Commit**

```bash
git add bin/setup
git commit -m "feat: add bin/setup with platform detection and helpers"
```

---

### Task 2: Add dependency check functions

**Files:**
- Modify: `bin/setup`

**Step 1: Add the version comparison helper and dependency check functions**

Append before the `detect_platform` call at the bottom:

```bash
# --- Version comparison ---
# Returns 0 if $1 >= $2 (numeric major or major.minor)
version_gte() {
  local have="$1" need="$2"
  # Split on dots
  local have_major="${have%%.*}" have_minor="${have#*.}"
  local need_major="${need%%.*}" need_minor="${need#*.}"
  # Handle no-dot versions (e.g. OTP "25")
  [[ "$have_major" == "$have" ]] && have_minor=0
  [[ "$need_major" == "$need" ]] && need_minor=0

  if (( have_major > need_major )); then return 0; fi
  if (( have_major < need_major )); then return 1; fi
  (( have_minor >= need_minor ))
}

# --- Dependency checks ---

check_erlang() {
  info "Checking Erlang/OTP..."
  if command -v erl &>/dev/null; then
    local ver
    ver=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')
    if version_gte "$ver" "25"; then
      ok "Erlang/OTP $ver"
      return
    else
      warn "Erlang/OTP $ver found, but >= 25 required"
    fi
  else
    warn "Erlang/OTP not found"
  fi

  local cmd
  case "$PKG" in
    brew) cmd="brew install erlang" ;;
    apt)  cmd="sudo apt-get install -y erlang" ;;
    dnf)  cmd="sudo dnf install -y erlang" ;;
  esac

  if ask "Install Erlang/OTP? ($cmd)"; then
    eval "$cmd"
    ok "Erlang/OTP installed"
  else
    fail "Erlang/OTP is required"
    MISSING_CRITICAL=1
  fi
}

check_elixir() {
  info "Checking Elixir..."
  if command -v elixir &>/dev/null; then
    local ver
    ver=$(elixir --version | grep -oE 'Elixir [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+')
    if version_gte "$ver" "1.15"; then
      ok "Elixir $ver"
      return
    else
      warn "Elixir $ver found, but >= 1.15 required"
    fi
  else
    warn "Elixir not found"
  fi

  local cmd
  case "$PKG" in
    brew) cmd="brew install elixir" ;;
    apt)  cmd="sudo apt-get install -y elixir" ;;
    dnf)  cmd="sudo dnf install -y elixir" ;;
  esac

  if ask "Install Elixir? ($cmd)"; then
    eval "$cmd"
    ok "Elixir installed"
  else
    fail "Elixir is required"
    MISSING_CRITICAL=1
  fi
}

check_zig() {
  info "Checking Zig..."
  if command -v zig &>/dev/null; then
    ok "Zig $(zig version)"
    return
  fi

  warn "Zig not found"
  local cmd
  case "$PKG" in
    brew) cmd="brew install zig" ;;
    apt)  cmd="sudo snap install zig --classic --beta" ;;
    dnf)  cmd="sudo dnf install -y zig" ;;
  esac

  if ask "Install Zig? ($cmd)"; then
    eval "$cmd"
    ok "Zig installed"
  else
    fail "Zig is required (builds the PTY port)"
    MISSING_CRITICAL=1
  fi
}

check_node() {
  info "Checking Node.js..."
  if command -v node &>/dev/null; then
    ok "Node.js $(node --version)"
    return
  fi

  warn "Node.js not found"
  local cmd
  case "$PKG" in
    brew) cmd="brew install node" ;;
    apt)  cmd="sudo apt-get install -y nodejs" ;;
    dnf)  cmd="sudo dnf install -y nodejs" ;;
  esac

  if ask "Install Node.js? ($cmd)"; then
    eval "$cmd"
    ok "Node.js installed"
  else
    fail "Node.js is required (asset compilation)"
    MISSING_CRITICAL=1
  fi
}

check_chromedriver() {
  info "Checking chromedriver (optional, for E2E tests)..."
  if command -v chromedriver &>/dev/null; then
    ok "chromedriver $(chromedriver --version 2>/dev/null | head -1)"
    return
  fi

  warn "chromedriver not found (only needed for E2E tests)"
  local cmd
  case "$PKG" in
    brew) cmd="brew install --cask chromedriver" ;;
    apt)  cmd="sudo apt-get install -y chromium-chromedriver" ;;
    dnf)  cmd="sudo dnf install -y chromedriver" ;;
  esac

  if ask "Install chromedriver? ($cmd)"; then
    eval "$cmd"
    ok "chromedriver installed"
  else
    ok "Skipped (E2E tests won't run)"
  fi
}
```

**Step 2: Wire up the checks in the main flow at the bottom of the script**

Replace the bottom section (after `detect_platform`) with:

```bash
detect_platform
info "Detected: $OS ($PKG)"
echo ""

# --- Check dependencies ---
check_erlang
echo ""
check_elixir
echo ""
check_zig
echo ""
check_node
echo ""
check_chromedriver
echo ""

if (( MISSING_CRITICAL )); then
  echo ""
  fail "Some required dependencies are missing. Install them and re-run ./bin/setup"
  exit 1
fi
```

**Step 3: Test it**

Run:
```bash
bin/setup
```
Expected: Each dep checked, green checkmarks for installed ones. No install prompts if everything is present.

**Step 4: Commit**

```bash
git add bin/setup
git commit -m "feat: add dependency checks with version validation"
```

---

### Task 3: Add project setup phase

**Files:**
- Modify: `bin/setup`

**Step 1: Add project setup after dependency checks**

Append to the bottom of the script (after the `MISSING_CRITICAL` check):

```bash
# --- Project setup ---
echo ""
info "Setting up Elixir project..."
echo ""

info "Installing Hex and Rebar..."
mix local.hex --force --if-missing
mix local.rebar --force --if-missing
ok "Hex and Rebar ready"
echo ""

info "Running mix setup (deps, Zig build, assets)..."
mix setup
ok "Project setup complete"

echo ""
echo -e "${GREEN}${BOLD}=== Setup complete! ===${NC}"
echo ""
echo "  Start the dev server:"
echo ""
echo -e "    ${CYAN}mix phx.server${NC}"
echo ""
echo "  Then open http://localhost:4000"
echo ""
```

**Step 2: Test the full flow**

Run:
```bash
bin/setup
```
Expected: Dep checks pass, then mix setup runs (may be fast if already set up), prints success banner.

**Step 3: Commit**

```bash
git add bin/setup
git commit -m "feat: add project setup phase to bin/setup"
```

---

### Task 4: Update README to reference `bin/setup`

**Files:**
- Modify: `README.md`

**Step 1: Update the Installation section**

Replace the current Installation section (lines ~46-58) with:

```markdown
## Installation

```bash
# Clone the repo
git clone https://github.com/jonohrt/secret-agent-man.git
cd secret-agent-man

# Bootstrap everything (checks deps, installs missing ones, builds project)
./bin/setup

# Start the development server
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000) in your browser.

> **Already have Elixir, Zig, and Node installed?** You can skip the bootstrap and run `mix setup` directly.
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README installation to use bin/setup"
```

---

### Task 5: Manual verification

**Step 1: Run the full script end-to-end**

```bash
bin/setup
```

Verify:
- Platform detected correctly
- All deps show green checkmarks
- No errors from mix setup
- Success banner prints

**Step 2: Verify README reads well**

```bash
cat README.md
```

Check the Installation section flows naturally.

**Step 3: Run precommit**

```bash
mix precommit
```

Expected: All checks pass.

**Step 4: Final commit if any cleanup needed**
