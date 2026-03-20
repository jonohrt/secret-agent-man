# Blue-Steel Command Center — UI Redesign Spec

## Overview

Full visual redesign of the SAM dashboard from the current retro CRT monospace aesthetic to a "Blue-Steel Command Center" design language inspired by tactical intelligence interfaces. The redesign touches CSS, typography, layout structure, and LiveView templates while preserving the existing backend architecture (PubSub, process tree, status state machine).

### Goals

- Replace the 4-theme system with a single cohesive "Command" theme, keeping CSS custom property infrastructure for future theming
- Move from monospace-everything to a professional 3-font type system
- Restructure the dashboard from a simple 2-column grid to a bento grid layout with embedded terminal
- Add branding (logo, wordmark), agent hierarchy panel, and spy-fiction session creation modal

### Non-Goals

- Backend changes (Server, Parser, PTY, Summarizer are untouched)
- Sub-agent tracking — the `agents` field exists in Server state but is never populated. The Agents Panel is designed to support multiple agents in the future, but the initial implementation shows only the main agent per session. Sub-agent data flow is a separate backend feature.
- Mobile responsiveness (desktop-first, as the current app is)

---

## Design System

### Color Palette

The palette is rooted in deep navy/slate, with blue-steel primary and phosphor green for terminal/active states.

| Token | Hex | Usage |
|---|---|---|
| `--surface` | `#061423` | App background |
| `--surface-container-lowest` | `#020f1e` | Terminal background, deepest inset |
| `--surface-container-low` | `#0f1c2c` | Panel backgrounds |
| `--surface-container` | `#132030` | Selected/active states |
| `--surface-container-high` | `#1e2b3b` | Panel headers, elevated elements |
| `--surface-container-highest` | `#283646` | Terminal top border, surface-variant |
| `--surface-bright` | `#2d3a4a` | Glassmorphism base |
| `--primary` | `#afc9ea` | Primary actions, links, selected tab |
| `--on-primary` | `#17324d` | Text on primary buttons |
| `--secondary` | `#bbc6e2` | Secondary text/elements |
| `--phosphor-green` | `#22c55e` | Terminal text, active/working status, "(ager)" glow |
| `--on-surface` | `#d6e4f9` | Primary text |
| `--on-surface-variant` | `#c3c6ce` | Secondary text |
| `--outline` | `#8d9198` | Muted labels, timestamps |
| `--outline-variant` | `#43474d` | Borders, dividers (at low opacity) |
| `--error` | `#ffb4ab` | Error status, destructive actions |

All colors are defined as CSS custom properties on `:root` / `[data-theme="command"]` to preserve theming infrastructure.

### Typography

Three font families replace the current monospace-only approach:

| Family | Font | Usage |
|---|---|---|
| `--font-headline` | Space Grotesk | Logo, session names, panel headers, buttons, tab labels |
| `--font-body` | Inter | Body text, form labels, descriptions |
| `--font-mono` | JetBrains Mono | Terminal, timestamps, metadata, status codes, agent names |

Loaded via Google Fonts. The current system font stack remains as fallback.

**Typography scale:**

- Panel headers: 8-9px, Space Grotesk, uppercase, `letter-spacing: 0.15em`, weight 700
- Tab labels: 9px, Space Grotesk, uppercase, `letter-spacing: 0.08em`, weight 600
- Session name: 16px, Space Grotesk, weight 700, `letter-spacing: -0.02em`
- Body text: 11px, Inter
- Metadata/timestamps: 8-9px, JetBrains Mono
- Status text: 7-8px, JetBrains Mono, uppercase

### CRT Effects

Retained from current design but adapted:

- **Scanlines**: `linear-gradient` overlay at 15% opacity, `background-size: 100% 4px`
- **Phosphor glow**: `text-shadow: 0 0 5px rgba(34,197,94,0.3)` on terminal text only
- **Status dot glow**: `box-shadow: 0 0 6px` at 50% opacity of the status color

### Borders & Surfaces

- No visible 1px borders for section separation — use tonal shifts between surface levels
- Panel borders: `1px solid #1e2b3b` (subtle, structural)
- Dividers within panels: `1px solid rgba(67,71,77,0.12)` (ghost borders)
- Terminal top accent: `3px solid #283646`
- Active/selected states: `border-left: 3px solid #afc9ea`
- Border radius: `0` everywhere (sharp, tactical)

---

## Layout Structure

### Overall Hierarchy

```
Top Nav (logo + global actions)         — fixed, 44px height
Tab Bar (session tabs + deploy button)  — fixed, 36px height
Status Bar (session name + metadata)    — within content flow
Bento Grid                              — fills remaining viewport
  ├── Terminal (8/12 cols, spans 2 rows)
  ├── Activity Feed (4/12 cols, top)
  └── Agents Panel (4/12 cols, bottom)
Footer (session count + theme info)     — fixed, bottom
```

### Top Nav Bar

- **Left**: Logo (SVG crosshair/agent icon) + "Secret Agent Man(ager)" wordmark
  - "Secret Agent Man" in `--primary` (#afc9ea)
  - Parentheses in `--outline-variant` (#43474d)
  - "ager" in `--phosphor-green` (#22c55e) with green text-shadow glow
  - Subtitle: "TACTICAL AGENT COMMAND" in JetBrains Mono, 7px, `--outline`
- **Right**: Two icon buttons
  - Gear icon + "SETTINGS" — `--outline` color, hover brightens
  - Crosshair/target icon + "KILL ALL" — `--error` color, hover intensifies

### Tab Bar

Preserves current tab-based session switching. Each tab shows:

- Status dot (colored + glow matching session status)
- Session name (uppercase, Space Grotesk)
- Active tab: `--primary` text, `border-bottom: 2px solid --primary`, `--surface-container` background
- Inactive tabs: `--outline` text
- Right side: "+ DEPLOY AGENT" button (solid `--primary` background)

### Session Status Bar

New element between tabs and bento grid. Single horizontal bar containing:

- **Session name**: 16px Space Grotesk bold
- **Status badge**: Dot + status text (e.g., "WORKING") in a bordered pill
- **Metadata**: Working directory, branch name, uptime — JetBrains Mono, `--outline`
- **Actions** (right-aligned):
  - "SEND INPUT" — outline button in `--primary`
  - "TERMINATE" — outline button in `--error`

### Bento Grid

CSS Grid: `grid-template-columns: 8fr 4fr`, two rows, `gap: 10px`, `padding: 10px`.

#### Terminal Panel (8 cols, row span 2)

- **Indicator bar**: "VIEWING: [agent-name]" with green live dot and "LIVE" label. Blue bottom border (`2px solid --primary`). This replaces the cluttered sub-agent tabs — the agent panel drives which agent's terminal is shown.
- **Terminal body**: `--surface-container-lowest` background, phosphor green text with CRT glow. xterm.js renders here (existing Terminal hook).
- **Top accent**: `3px solid --surface-container-highest`

#### Activity Feed (4 cols, top right)

- Panel header: "ACTIVITY FEED" + "LIVE" indicator
- Scrollable list of timestamped events
- Timestamp in `--primary` at 50% opacity, JetBrains Mono
- Event text in `--on-surface-variant`
- System events (session started, tests passing) in `--phosphor-green`
- Agent spawn events in `--primary` with ↳ prefix

#### Agents Panel (4 cols, bottom right)

- Panel header: "AGENTS" + count
- Two-line rows per agent (option B from brainstorming):
  - **Top line**: Status dot + agent name (JetBrains Mono) + badge ("PRIMARY" for main agent) + status text
  - **Bottom line**: Activity description in `--outline`, 8px, truncated with ellipsis
- **Selected agent**: `--surface-container` background, `border-left: 3px solid --primary`
- **Click behavior**: Switches the terminal panel to show that agent's PTY output. Updates the "VIEWING:" indicator.
- **Status colors**:
  - Working: `--phosphor-green`
  - Complete/Done: `--primary`
  - Idle: `--outline`
  - Error: `--error`

**Initial implementation (v1):** The panel shows only the main agent per session, since sub-agent data is not yet populated in the backend. The panel structure (two-line rows, click-to-switch) is built out so that when sub-agent tracking is added to Server, the UI is ready. In v1, the single main agent row is always selected and the "VIEWING:" indicator always reads "main".

### Footer

Fixed bottom bar, `--surface-container-lowest` background:

- Left: Session count, agent count, current theme name
- Right: "CTRL+T: CYCLE THEME"

---

## Session Creation Modal

Triggered by "+ DEPLOY AGENT" button. Overlays the dashboard.

### Overlay

- Background: `rgba(6,20,35,0.85)` with `backdrop-filter: blur(4px)`
- Centers the modal panel vertically and horizontally

### Modal Panel

- **Glassmorphism**: `rgba(45,58,74,0.6)` background, `backdrop-filter: blur(16px)`, `border: 1px solid rgba(175,201,234,0.12)`
- **Blueprint grid**: Subtle CSS grid pattern overlay at 30% opacity
- **Scanning line**: Gradient bar at bottom edge for visual flair
- **Shadow**: `0 24px 48px rgba(0,0,0,0.4)`

### Content

- **Header**: "CLASSIFIED" badge (dark olive background) + divider line + "REF: SC-2024-XP" reference
- **Title**: "NEW OPERATION" — 20px Space Grotesk, uppercase, tracking

### Form Fields

| Field | Label | Type | Placeholder |
|---|---|---|---|
| Session name | SESSION_IDENTITY | Text input | "ENTER OPERATION CODENAME..." |
| Agent type | AGENT_SPECIFICATION | Select dropdown | CLAUDE_CODE, OPEN_CODE, etc. |
| Working directory | DEPLOYMENT_VECTOR | Text input (mono) | "/ROOT/PROJECTS/..." |
| Initial prompt | INITIAL_DIRECTIVES | Textarea (3 rows) | "DESCRIBE THE TARGET ARCHITECTURE AND OBJECTIVES..." |

- Labels: 9px Inter, bold, uppercase, `letter-spacing: 0.12em`, `--primary` color
- Inputs: Transparent background, bottom-border only (`1px solid --outline-variant`), focus brightens border to `--primary`
- Agent type and working directory side-by-side (2-column grid)

### Footer Actions

- **Left**: "ABORT_MISSION" text button with X icon, `--outline` color, hover changes to `--error`
- **Right**: Authorization text ("LVL_07_ACCESS_GRANTED") + "INITIATE OPERATION" solid button (`--primary` background, box-shadow glow)

---

## Theme Infrastructure

### Migration Plan

1. Replace `themes.css` content — remove tron/synthwave/phosphor/amber theme definitions
2. Define single `[data-theme="command"]` theme using CSS custom properties
3. Keep the same property names where possible for continuity:
   - `--bg-primary` → maps to `--surface`
   - `--bg-secondary` → maps to `--surface-container-low`
   - `--bg-tertiary` → maps to `--surface-container-high`
   - `--accent` → maps to `--primary`
   - `--accent-glow` → maps to `--primary` at reduced opacity
   - `--text-primary` → maps to `--on-surface`
   - `--text-secondary` → maps to `--on-surface-variant`
   - `--text-muted` → maps to `--outline`
   - Status colors remain the same property names
4. Old property names (`--bg-primary`, `--accent`, etc.) are removed entirely — all CSS is rewritten to use the new token names. No aliases needed since we're rewriting all stylesheets in this pass.
5. Keep `theme.js` with `initTheme()` / `applyTheme()` / `cycleTheme()` — just only one theme for now
6. Keep `Ctrl+T` cycling infrastructure but hide "CTRL+T: CYCLE THEME" from the footer when only one theme exists. Show it conditionally when `themes.length > 1`.

### Future Theming

The CSS custom property system stays intact. Adding a new theme means:
1. Add a new `[data-theme="amber-tactical"]` block in `themes.css`
2. Add the theme name to the `themes` array in `theme.js`
3. Everything else (layout, components, typography) stays the same

---

## Files Changed

| File | Change |
|---|---|
| `assets/css/app.css` | Rewrite — new component styles, typography, layout grid, CRT effects |
| `assets/css/themes.css` | Rewrite — single "command" theme with new color tokens |
| `assets/js/theme.js` | Update themes array to `['command']`, keep infrastructure |
| `assets/js/terminal.js` | Update hardcoded tron colors to use new palette |
| `lib/sam_web/live/dashboard_live.ex` | Rewrite template — new layout structure (top nav, tabs, status bar, bento grid, agents panel, modal) |
| `lib/sam_web/components/layouts/root.html.heex` | Add Google Fonts imports, update default theme class |

### New Assets

- SVG logo (inline in template, no separate file needed)
- Google Fonts: Space Grotesk, Inter, JetBrains Mono (loaded via CDN link in root layout)

### Files NOT Changed

- `lib/sam/session/server.ex` — No backend changes
- `lib/sam/session/parser.ex` — No backend changes
- `lib/sam/session/pty.ex` — No backend changes
- `lib/sam/session/summarizer.ex` — No backend changes
- `assets/js/app.js` — Minimal changes (hook registration stays the same)

---

## Interactions & Behavior

### Tab Switching

Same as current: clicking a tab sends a `phx-click` event that updates the selected session. The bento grid, status bar, terminal, activity feed, and agents panel all update to reflect the selected session.

### Agent Selection

New behavior: clicking an agent row in the Agents panel switches the terminal to show that agent's PTY output. The "VIEWING: [agent-name]" indicator updates. The main agent is selected by default.

### Terminal

The terminal remains an xterm.js instance managed by the existing `Terminal` hook. The change is structural — it's embedded in the bento grid rather than rendered as a full-page overlay. The hook's resize logic needs to account for the new container dimensions.

### Session Creation

The "+ DEPLOY AGENT" button shows the glassmorphism modal. "INITIATE OPERATION" submits the form (same `phx-submit` as current). "ABORT_MISSION" or clicking the overlay dismisses it.

### Send Input

When the session status is `:needs_input`, the status bar transforms to show the input UI inline:

- The status badge changes to "NEEDS INPUT" in `--primary` with a pulsing glow to draw attention
- The right side of the status bar replaces the action buttons with: a text input field (JetBrains Mono, `--surface-container-lowest` background, bottom-border only, `--primary` caret) + quick-response buttons ("YES" / "NO" in small outlined pills) + a submit button
- The text input auto-focuses when the status transitions to `:needs_input`
- Submitting (Enter key or submit button) sends the input via the existing `send_input` event and the status bar returns to normal

When the session is NOT in `:needs_input`, the "SEND INPUT" button is shown as a fallback for manually sending text to the PTY (existing behavior).

### Status Dot Glow

Status dots use `box-shadow` with the status color at 50% opacity:
- `:working` — green glow
- `:needs_input` — primary (blue) glow
- `:idle` — no glow (dim dot)
- `:error` — red glow
- `:done` — primary (blue), no glow
- `:starting` — primary (blue), pulsing animation

---

## Testing Considerations

- All changes are frontend-only (CSS, templates, JS)
- Existing LiveView tests should still pass since the backend data model is unchanged
- The `phx-click`, `phx-submit`, and PubSub event handlers remain the same
- Terminal hook behavior is preserved — only the container sizing changes
- Manual visual testing needed for: layout at various viewport sizes, CRT effects, glassmorphism modal, agent panel click-to-switch
