# Blue-Steel Command Center UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the SAM dashboard from retro CRT monospace to a "Blue-Steel Command Center" aesthetic with bento grid layout, embedded terminal, agent panel, and spy-fiction session creation modal.

**Architecture:** Frontend-only rewrite of CSS (new theme tokens + component styles), LiveView template (bento grid layout with top nav, tab bar, status bar, terminal, activity feed, agents panel), and JS (terminal theme integration, theme system simplification). Backend unchanged.

**Tech Stack:** Phoenix LiveView (HEEx templates), CSS custom properties, Google Fonts (Space Grotesk, Inter, JetBrains Mono), xterm.js, existing PubSub infrastructure.

**Spec:** `docs/superpowers/specs/2026-03-20-blue-steel-ui-redesign.md`

---

### File Map

| File | Action | Responsibility |
|---|---|---|
| `assets/css/themes.css` | Rewrite | Single "command" theme with new color tokens as CSS custom properties |
| `assets/css/app.css` | Rewrite | All component styles: top nav, tabs, status bar, bento grid, panels, terminal chrome, modal, CRT effects |
| `assets/js/theme.js` | Modify | Simplify to single "command" theme, keep cycling infrastructure |
| `assets/js/terminal.js` | Modify | Replace hardcoded TRON colors with command palette colors |
| `lib/sam_web/components/layouts/root.html.heex` | Modify | Add Google Fonts imports, update default theme class to "command" |
| `lib/sam_web/live/dashboard_live.ex` | Rewrite render | New template: top nav, tab bar, status bar, bento grid, agents panel, modal |

---

### Task 1: Theme Tokens & Typography Foundation

**Files:**
- Rewrite: `assets/css/themes.css`
- Modify: `lib/sam_web/components/layouts/root.html.heex`
- Modify: `assets/js/theme.js`

- [ ] **Step 1: Rewrite themes.css with the command theme**

Replace the entire file with a single `[data-theme="command"]` block. Keep the CSS custom property naming pattern for future theming.

```css
/* Command Center — Blue-Steel Theme
   Single theme for now. Add additional [data-theme="..."] blocks for new themes.
   Keep property names stable — components reference these tokens. */

[data-theme="command"] {
  /* Surface hierarchy (dark → light) */
  --surface: #061423;
  --surface-container-lowest: #020f1e;
  --surface-container-low: #0f1c2c;
  --surface-container: #132030;
  --surface-container-high: #1e2b3b;
  --surface-container-highest: #283646;
  --surface-bright: #2d3a4a;

  /* Brand */
  --primary: #afc9ea;
  --on-primary: #17324d;
  --phosphor-green: #22c55e;

  /* Text */
  --on-surface: #d6e4f9;
  --on-surface-variant: #c3c6ce;
  --outline: #8d9198;
  --outline-variant: #43474d;

  /* Semantic */
  --secondary: #bbc6e2;
  --error: #ffb4ab;

  /* Status indicators */
  --status-working: #22c55e;
  --status-input: #afc9ea;
  --status-idle: #8d9198;
  --status-error: #ffb4ab;
  --status-done: #afc9ea;
  --status-starting: #afc9ea;

  /* Effects */
  --scanline-opacity: 0.15;
  --glow-green: rgba(34, 197, 94, 0.3);
  --glow-primary: rgba(175, 201, 234, 0.2);
  --glow-error: rgba(255, 180, 171, 0.4);

  /* Typography */
  --font-headline: 'Space Grotesk', system-ui, sans-serif;
  --font-body: 'Inter', system-ui, sans-serif;
  --font-mono: 'JetBrains Mono', 'Courier New', monospace;
}
```

- [ ] **Step 2: Update root layout for Google Fonts and new default theme**

In `lib/sam_web/components/layouts/root.html.heex`:

1. Add Google Fonts link in `<head>` (after existing stylesheet links):
```html
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@300;400;500;600;700&family=Inter:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet" />
```

2. Change the `<body>` tag from `class="theme-tron"` to `data-theme="command"`.

3. Update the inline `<script>` block: change the `setTheme()` function to set `document.documentElement.setAttribute("data-theme", theme)` and change the default from `"system"` to `"command"`. Remove the `document.body.className` approach.

- [ ] **Step 3: Simplify theme.js**

Replace `assets/js/theme.js` with:

```javascript
const THEMES = ['command']
const STORAGE_KEY = 'sam-theme'

export function initTheme() {
  const saved = localStorage.getItem(STORAGE_KEY)
  const theme = THEMES.includes(saved) ? saved : THEMES[0]
  applyTheme(theme)
}

export function cycleTheme() {
  const current = getCurrentTheme()
  const idx = THEMES.indexOf(current)
  const next = THEMES[(idx + 1) % THEMES.length]
  applyTheme(next)
  return next
}

export function applyTheme(name) {
  document.documentElement.setAttribute('data-theme', name)
  localStorage.setItem(STORAGE_KEY, name)
}

export function getCurrentTheme() {
  return localStorage.getItem(STORAGE_KEY) || THEMES[0]
}

export function getThemeCount() {
  return THEMES.length
}

document.addEventListener('keydown', (e) => {
  if (e.ctrlKey && e.key === 't') {
    e.preventDefault()
    cycleTheme()
  }
})
```

- [ ] **Step 4: Verify the app compiles and loads**

Run: `mix compile --warnings-as-errors`
Expected: PASS — no Elixir compilation errors.

Open `http://localhost:4000` in a browser. The page will look broken (old CSS references new tokens) — that's expected. Verify:
- Google Fonts load (check Network tab)
- `<html data-theme="command">` is present in DOM
- No JS console errors from theme.js

- [ ] **Step 5: Commit**

```bash
git add assets/css/themes.css assets/js/theme.js lib/sam_web/components/layouts/root.html.heex
git commit -m "feat: add command theme tokens, Google Fonts, and simplified theme system"
```

---

### Task 2: Base CSS — Layout Shell & CRT Effects

**Files:**
- Rewrite: `assets/css/app.css`

This task replaces all 591 lines of app.css with the new design system. The CSS is organized by component, top-to-bottom matching the layout hierarchy.

- [ ] **Step 1: Write the new app.css**

Replace the entire contents of `assets/css/app.css` with the new styles. The file imports themes.css and defines styles for:

1. **Reset & base** — box-sizing, body styling with `var(--font-body)`, selection colors
2. **CRT effects** — scanline overlay via `body::after`, phosphor glow tint via `body::before`
3. **Scrollbar** — thin dark scrollbars matching the surface palette
4. **Top nav** (.sam-topnav) — fixed, 44px, backdrop-blur, logo + actions
5. **Logo** (.sam-logo) — SVG icon + wordmark with green "(ager)" glow
6. **Tab bar** (.sam-tabs) — session tabs with status dots, deploy button
7. **Status bar** (.sam-status-bar) — session name, badge, metadata, action buttons
8. **Status dots** (.status-dot) — colored dots with glow box-shadow per status
9. **Bento grid** (.sam-bento) — `grid-template-columns: 8fr 4fr`, 2 rows
10. **Panel** (.sam-panel) — reusable panel with header bar
11. **Terminal panel** (.sam-terminal) — top accent border, viewing indicator, dark body
12. **Activity feed** (.activity-item) — timestamp + message rows
13. **Agent panel** (.agent-row) — two-line rows with status dot, name, badge, activity
14. **Input bar** (.sam-input-bar) — inline input in status bar for `:needs_input` state
15. **Modal** (.modal-overlay, .modal-panel) — glassmorphism overlay with blueprint grid
16. **Footer** (.sam-footer) — fixed bottom, connection info
17. **Buttons** (.sam-btn-deploy, .sam-btn-outline) — solid and outline variants

```css
@import "./themes.css";

/* ============================================
   BASE
   ============================================ */

*, *::before, *::after {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  font-family: var(--font-body);
  background: var(--surface);
  color: var(--on-surface);
  overflow: hidden;
  height: 100vh;
}

::selection {
  background: var(--primary);
  color: var(--on-primary);
}

/* ============================================
   CRT EFFECTS
   ============================================ */

body::after {
  content: '';
  position: fixed;
  inset: 0;
  background: linear-gradient(to bottom, rgba(18,16,16,0) 50%, rgba(0,0,0,0.15) 50%);
  background-size: 100% 4px;
  pointer-events: none;
  opacity: var(--scanline-opacity);
  z-index: 9999;
}

body::before {
  content: '';
  position: fixed;
  inset: 0;
  background: linear-gradient(to bottom, rgba(34,197,94,0.03), transparent, rgba(34,197,94,0.03));
  pointer-events: none;
  z-index: 9998;
}

/* ============================================
   SCROLLBAR
   ============================================ */

::-webkit-scrollbar { width: 4px; height: 4px; }
::-webkit-scrollbar-track { background: var(--surface-container-lowest); }
::-webkit-scrollbar-thumb { background: var(--surface-container-highest); }

/* ============================================
   DASHBOARD SHELL
   ============================================ */

.sam-shell {
  display: flex;
  flex-direction: column;
  height: 100vh;
  overflow: hidden;
}

/* ============================================
   TOP NAV
   ============================================ */

.sam-topnav {
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: rgba(6, 20, 35, 0.9);
  backdrop-filter: blur(12px);
  border-bottom: 1px solid var(--surface-container-high);
  padding: 0 16px;
  height: 44px;
  flex-shrink: 0;
}

.sam-logo {
  display: flex;
  align-items: center;
  gap: 10px;
}

.sam-logo svg {
  width: 24px;
  height: 24px;
  flex-shrink: 0;
}

.sam-logo-text {
  display: flex;
  flex-direction: column;
  line-height: 1;
}

.sam-logo-main {
  font-family: var(--font-headline);
  font-size: 14px;
  font-weight: 700;
  color: var(--primary);
  letter-spacing: -0.02em;
}

.sam-logo-main .paren {
  color: var(--outline-variant);
}

.sam-logo-main .ager {
  color: var(--phosphor-green);
  text-shadow: 0 0 8px var(--glow-green);
}

.sam-logo-sub {
  font-family: var(--font-mono);
  font-size: 7px;
  color: var(--outline);
  letter-spacing: 0.15em;
  margin-top: 2px;
}

.sam-topnav-actions {
  display: flex;
  align-items: center;
  gap: 6px;
}

.sam-topnav-btn {
  display: flex;
  align-items: center;
  gap: 5px;
  font-family: var(--font-headline);
  font-size: 9px;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--outline);
  padding: 5px 10px;
  cursor: pointer;
  border: none;
  background: transparent;
  transition: all 0.15s;
}

.sam-topnav-btn:hover {
  background: var(--surface-container-high);
  color: var(--on-surface-variant);
}

.sam-topnav-btn.danger {
  color: var(--error);
}

.sam-topnav-btn.danger:hover {
  background: rgba(147, 0, 10, 0.15);
}

.sam-topnav-btn svg {
  width: 14px;
  height: 14px;
  flex-shrink: 0;
}

/* ============================================
   TAB BAR
   ============================================ */

.sam-tabs {
  display: flex;
  align-items: center;
  background: #0a1929;
  border-bottom: 1px solid var(--surface-container-high);
  padding: 0 12px;
  height: 36px;
  flex-shrink: 0;
  overflow-x: auto;
}

.sam-tab {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 7px 14px;
  color: var(--outline);
  font-family: var(--font-headline);
  font-size: 9px;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  border-bottom: 2px solid transparent;
  cursor: pointer;
  white-space: nowrap;
  transition: color 0.15s;
}

.sam-tab:hover {
  color: var(--on-surface-variant);
}

.sam-tab.active {
  color: var(--primary);
  border-bottom-color: var(--primary);
  background: var(--surface-container);
}

.sam-tab-actions {
  margin-left: auto;
  flex-shrink: 0;
}

/* ============================================
   STATUS DOTS
   ============================================ */

.status-dot {
  width: 5px;
  height: 5px;
  border-radius: 50%;
  flex-shrink: 0;
  background: var(--outline);
}

.status-dot.working {
  background: var(--status-working);
  box-shadow: 0 0 6px rgba(34, 197, 94, 0.5);
}

.status-dot.needs_input {
  background: var(--status-input);
  box-shadow: 0 0 6px var(--glow-primary);
  animation: pulse-dot 2s ease-in-out infinite;
}

.status-dot.idle {
  background: var(--status-idle);
}

.status-dot.error {
  background: var(--status-error);
  box-shadow: 0 0 6px var(--glow-error);
}

.status-dot.done {
  background: var(--status-done);
}

.status-dot.starting {
  background: var(--status-starting);
  animation: pulse-dot 1.5s ease-in-out infinite;
}

.status-dot.running {
  background: var(--status-working);
  box-shadow: 0 0 6px rgba(34, 197, 94, 0.5);
}

@keyframes pulse-dot {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.4; }
}

/* ============================================
   STATUS BAR
   ============================================ */

.sam-status-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: var(--surface-container-low);
  border: 1px solid var(--surface-container-high);
  padding: 8px 14px;
  margin: 10px 10px 0 10px;
  flex-shrink: 0;
}

.sam-status-left {
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
}

.sam-session-name {
  font-family: var(--font-headline);
  font-size: 16px;
  font-weight: 700;
  letter-spacing: -0.02em;
  color: var(--on-surface);
  white-space: nowrap;
}

.sam-status-badge {
  display: flex;
  align-items: center;
  gap: 5px;
  background: var(--surface-container);
  padding: 2px 8px;
  border: 1px solid var(--outline-variant);
  font-family: var(--font-mono);
  font-size: 8px;
  font-weight: 700;
  letter-spacing: 0.12em;
  text-transform: uppercase;
  white-space: nowrap;
}

.sam-status-meta {
  font-family: var(--font-mono);
  font-size: 8px;
  color: var(--outline);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.sam-status-actions {
  display: flex;
  gap: 6px;
  flex-shrink: 0;
}

/* ============================================
   INPUT BAR (inline in status bar for :needs_input)
   ============================================ */

.sam-input-inline {
  display: flex;
  align-items: center;
  gap: 8px;
  flex: 1;
  min-width: 0;
}

.sam-input-inline input {
  flex: 1;
  background: var(--surface-container-lowest);
  border: none;
  border-bottom: 1px solid var(--outline-variant);
  padding: 4px 8px;
  color: var(--on-surface);
  font-family: var(--font-mono);
  font-size: 11px;
  outline: none;
  caret-color: var(--primary);
}

.sam-input-inline input:focus {
  border-bottom-color: var(--primary);
}

.sam-quick-btn {
  padding: 3px 10px;
  background: rgba(175, 201, 234, 0.1);
  border: 1px solid rgba(175, 201, 234, 0.2);
  color: var(--primary);
  font-family: var(--font-headline);
  font-size: 8px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  cursor: pointer;
  transition: background 0.15s;
}

.sam-quick-btn:hover {
  background: rgba(175, 201, 234, 0.2);
}

/* ============================================
   BUTTONS
   ============================================ */

.sam-btn-deploy {
  background: var(--primary);
  color: var(--on-primary);
  font-family: var(--font-headline);
  font-size: 8px;
  font-weight: 700;
  letter-spacing: 0.15em;
  text-transform: uppercase;
  padding: 4px 12px;
  border: none;
  cursor: pointer;
  transition: filter 0.15s;
}

.sam-btn-deploy:hover {
  filter: brightness(1.1);
}

.sam-btn-deploy:active {
  transform: scale(0.98);
}

.sam-btn-outline {
  padding: 4px 10px;
  border: 1px solid rgba(175, 201, 234, 0.25);
  background: transparent;
  color: var(--primary);
  font-family: var(--font-headline);
  font-size: 8px;
  font-weight: 700;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  cursor: pointer;
  transition: all 0.15s;
}

.sam-btn-outline:hover {
  background: rgba(175, 201, 234, 0.05);
}

.sam-btn-outline.danger {
  border-color: rgba(255, 180, 171, 0.25);
  color: var(--error);
}

.sam-btn-outline.danger:hover {
  background: rgba(147, 0, 10, 0.1);
}

/* ============================================
   BENTO GRID
   ============================================ */

.sam-bento {
  display: grid;
  grid-template-columns: 8fr 4fr;
  grid-template-rows: 1fr 1fr;
  gap: 10px;
  padding: 10px;
  flex: 1;
  min-height: 0;
  overflow: hidden;
}

/* ============================================
   PANELS
   ============================================ */

.sam-panel {
  background: var(--surface-container-low);
  border: 1px solid var(--surface-container-high);
  display: flex;
  flex-direction: column;
  overflow: hidden;
  min-height: 0;
}

.sam-panel-header {
  background: var(--surface-container-high);
  padding: 6px 10px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-family: var(--font-headline);
  font-size: 8px;
  font-weight: 700;
  letter-spacing: 0.15em;
  text-transform: uppercase;
  color: var(--outline);
  flex-shrink: 0;
}

.sam-panel-body {
  flex: 1;
  overflow-y: auto;
  min-height: 0;
}

/* ============================================
   TERMINAL PANEL
   ============================================ */

.sam-terminal {
  grid-row: span 2;
  border-top: 3px solid var(--surface-container-highest);
}

.sam-terminal-indicator {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 5px 10px;
  background: var(--surface-container-high);
  font-family: var(--font-mono);
  font-size: 8px;
  color: var(--primary);
  border-bottom: 2px solid var(--primary);
  flex-shrink: 0;
}

.sam-terminal-indicator .live-dot {
  width: 4px;
  height: 4px;
  border-radius: 50%;
  background: var(--phosphor-green);
  box-shadow: 0 0 4px rgba(34, 197, 94, 0.5);
}

.sam-terminal-indicator .live-label {
  margin-left: auto;
  font-family: var(--font-headline);
  font-size: 7px;
  font-weight: 700;
  letter-spacing: 0.1em;
  color: var(--outline);
}

.sam-terminal-body {
  flex: 1;
  background: var(--surface-container-lowest);
  min-height: 0;
  position: relative;
}

.sam-terminal-body .xterm {
  height: 100%;
}

/* ============================================
   ACTIVITY FEED
   ============================================ */

.activity-item {
  display: flex;
  gap: 6px;
  padding: 5px 10px;
  border-bottom: 1px solid rgba(67, 71, 77, 0.1);
  font-size: 9px;
}

.activity-item .time {
  color: var(--primary);
  opacity: 0.5;
  font-family: var(--font-mono);
  font-size: 8px;
  white-space: nowrap;
  flex-shrink: 0;
}

.activity-item .msg {
  color: var(--on-surface-variant);
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.activity-item .msg.system {
  color: var(--phosphor-green);
}

.activity-item .msg.agent-event {
  color: var(--primary);
}

/* ============================================
   AGENT PANEL
   ============================================ */

.agent-row {
  display: flex;
  flex-direction: column;
  gap: 2px;
  padding: 8px 10px;
  cursor: pointer;
  border-bottom: 1px solid rgba(67, 71, 77, 0.12);
  transition: background 0.15s;
}

.agent-row:hover {
  background: var(--surface-container);
}

.agent-row.selected {
  background: var(--surface-container);
  border-left: 3px solid var(--primary);
  padding-left: 7px;
}

.agent-row-top {
  display: flex;
  align-items: center;
  gap: 6px;
}

.agent-name {
  font-family: var(--font-mono);
  font-size: 9px;
  font-weight: 500;
  color: var(--on-surface);
  flex: 1;
}

.agent-name.sub {
  color: var(--on-surface-variant);
}

.agent-badge {
  font-family: var(--font-headline);
  font-size: 6px;
  font-weight: 700;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  padding: 1px 4px;
  background: rgba(175, 201, 234, 0.12);
  color: var(--primary);
  border: 1px solid rgba(175, 201, 234, 0.2);
}

.agent-status {
  font-family: var(--font-mono);
  font-size: 7px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  flex-shrink: 0;
}

.agent-status.working { color: var(--status-working); }
.agent-status.done { color: var(--status-done); }
.agent-status.idle { color: var(--status-idle); }
.agent-status.error { color: var(--status-error); }

.agent-activity {
  font-family: var(--font-mono);
  font-size: 8px;
  color: var(--outline);
  padding-left: 11px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* ============================================
   SESSION CREATION MODAL
   ============================================ */

.modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(6, 20, 35, 0.85);
  backdrop-filter: blur(4px);
  z-index: 100;
  display: flex;
  align-items: center;
  justify-content: center;
}

.modal-panel {
  background: rgba(45, 58, 74, 0.6);
  backdrop-filter: blur(16px);
  border: 1px solid rgba(175, 201, 234, 0.12);
  width: 100%;
  max-width: 560px;
  position: relative;
  overflow: hidden;
  box-shadow: 0 24px 48px rgba(0, 0, 0, 0.4);
}

.modal-grid-bg {
  position: absolute;
  inset: 0;
  background-image:
    linear-gradient(rgba(67, 71, 77, 0.06) 1px, transparent 1px),
    linear-gradient(90deg, rgba(67, 71, 77, 0.06) 1px, transparent 1px);
  background-size: 20px 20px;
  pointer-events: none;
  opacity: 0.5;
}

.modal-scan {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 2px;
  background: linear-gradient(90deg, transparent, rgba(175, 201, 234, 0.3), transparent);
}

.modal-content {
  position: relative;
  padding: 24px;
}

.modal-header {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 6px;
}

.modal-classified {
  background: #575956;
  padding: 2px 8px;
  font-family: var(--font-headline);
  font-size: 8px;
  font-weight: 700;
  letter-spacing: 0.15em;
  color: #cecfcc;
  text-transform: uppercase;
}

.modal-divider {
  flex: 1;
  height: 1px;
  background: rgba(67, 71, 77, 0.3);
}

.modal-ref {
  font-family: var(--font-mono);
  font-size: 8px;
  color: rgba(175, 201, 234, 0.4);
}

.modal-title {
  font-family: var(--font-headline);
  font-size: 20px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--on-surface);
  margin: 8px 0 20px 0;
}

.modal-field {
  margin-bottom: 16px;
}

.modal-label {
  font-family: var(--font-body);
  font-size: 9px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--primary);
  margin-bottom: 6px;
  display: block;
}

.modal-input {
  width: 100%;
  background: transparent;
  border: none;
  border-bottom: 1px solid var(--outline-variant);
  padding: 6px 0;
  color: var(--on-surface);
  font-family: var(--font-body);
  font-size: 11px;
  outline: none;
  transition: border-color 0.15s;
}

.modal-input:focus {
  border-bottom-color: var(--primary);
}

.modal-input::placeholder {
  color: rgba(141, 145, 152, 0.5);
}

.modal-input-row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 16px;
}

.modal-select {
  width: 100%;
  background: transparent;
  border: none;
  border-bottom: 1px solid var(--outline-variant);
  padding: 6px 0;
  color: var(--on-surface);
  font-family: var(--font-body);
  font-size: 11px;
  appearance: none;
  cursor: pointer;
}

.modal-textarea {
  width: 100%;
  background: var(--surface-container-low);
  border: none;
  border-bottom: 1px solid var(--outline-variant);
  padding: 10px;
  color: var(--on-surface);
  font-family: var(--font-body);
  font-size: 11px;
  resize: none;
  outline: none;
  transition: border-color 0.15s;
}

.modal-textarea:focus {
  border-bottom-color: var(--primary);
}

.modal-textarea::placeholder {
  color: rgba(141, 145, 152, 0.4);
}

.modal-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-top: 20px;
  padding-top: 16px;
}

.modal-abort {
  font-family: var(--font-body);
  font-size: 9px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  color: var(--outline);
  cursor: pointer;
  background: none;
  border: none;
  display: flex;
  align-items: center;
  gap: 4px;
  transition: color 0.15s;
}

.modal-abort:hover {
  color: var(--error);
}

.modal-submit {
  background: var(--primary);
  color: var(--on-primary);
  font-family: var(--font-body);
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.12em;
  padding: 10px 20px;
  border: none;
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 8px;
  box-shadow: 0 0 20px var(--glow-primary);
  transition: all 0.15s;
}

.modal-submit:hover {
  filter: brightness(1.1);
  box-shadow: 0 0 30px rgba(175, 201, 234, 0.3);
}

.modal-submit:active {
  transform: scale(0.98);
}

.modal-auth {
  font-family: var(--font-mono);
  font-size: 7px;
  color: var(--outline);
  text-align: right;
  line-height: 1.5;
}

/* ============================================
   FOOTER
   ============================================ */

.sam-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 5px 14px;
  background: var(--surface-container-lowest);
  border-top: 1px solid var(--surface-container-high);
  font-family: var(--font-mono);
  font-size: 7px;
  color: var(--outline);
  flex-shrink: 0;
}

.sam-footer-dot {
  display: inline-block;
  width: 4px;
  height: 4px;
  border-radius: 50%;
  margin-right: 4px;
}
```

- [ ] **Step 2: Verify CSS compiles**

Run: `mix assets.build` (or check the esbuild/tailwind watcher output)
Expected: No build errors.

- [ ] **Step 3: Commit**

```bash
git add assets/css/app.css
git commit -m "feat: rewrite app.css with blue-steel command center component styles"
```

---

### Task 3: Terminal Theme Update

**Files:**
- Modify: `assets/js/terminal.js`

- [ ] **Step 1: Replace hardcoded TRON colors with command palette**

In `assets/js/terminal.js`, find the Terminal constructor (around lines 12-23) and replace the theme object:

```javascript
// OLD (hardcoded TRON):
theme: {
  background: '#0a0a1a',
  foreground: '#e0e0e0',
  cursor: '#00ffff',
  cursorAccent: '#0a0a1a',
  selectionBackground: 'rgba(0, 255, 255, 0.3)',
}

// NEW (command palette):
theme: {
  background: '#020f1e',
  foreground: '#d6e4f9',
  cursor: '#22c55e',
  cursorAccent: '#020f1e',
  selectionBackground: 'rgba(175, 201, 234, 0.3)',
  black: '#061423',
  red: '#ffb4ab',
  green: '#22c55e',
  yellow: '#afc9ea',
  blue: '#afc9ea',
  magenta: '#bbc6e2',
  cyan: '#afc9ea',
  white: '#d6e4f9',
}
```

- [ ] **Step 2: Verify terminal renders with new colors**

Open `http://localhost:4000`, start a session, and open the terminal. Verify:
- Background is dark navy (#020f1e)
- Text is light blue-white (#d6e4f9)
- Cursor is phosphor green (#22c55e)
- No JS console errors

- [ ] **Step 3: Commit**

```bash
git add assets/js/terminal.js
git commit -m "feat: update terminal colors to command palette"
```

---

### Task 4: LiveView Template — Layout Shell

**Files:**
- Modify: `lib/sam_web/live/dashboard_live.ex` (render function, lines 150-299)

This is the largest task. The render function is rewritten to produce the new layout structure. The event handlers (mount, handle_event, handle_info) stay the same — only the HEEx template changes.

- [ ] **Step 1: Rewrite the render function**

Replace the `render/1` function in `dashboard_live.ex` (approximately lines 150-299) with the new template. Keep all existing assigns and event handlers unchanged.

The new template structure:

```heex
<div class="sam-shell">
  <%!-- TOP NAV --%>
  <nav class="sam-topnav">
    <div class="sam-logo">
      <svg viewBox="0 0 28 28" width="24" height="24" fill="none" xmlns="http://www.w3.org/2000/svg">
        <circle cx="14" cy="14" r="12" stroke="#afc9ea" stroke-width="0.8" opacity="0.3"/>
        <line x1="14" y1="2" x2="14" y2="7" stroke="#afc9ea" stroke-width="0.8" opacity="0.4"/>
        <line x1="14" y1="21" x2="14" y2="26" stroke="#afc9ea" stroke-width="0.8" opacity="0.4"/>
        <line x1="2" y1="14" x2="7" y2="14" stroke="#afc9ea" stroke-width="0.8" opacity="0.4"/>
        <line x1="21" y1="14" x2="26" y2="14" stroke="#afc9ea" stroke-width="0.8" opacity="0.4"/>
        <circle cx="14" cy="14" r="6" stroke="#22c55e" stroke-width="1.2" opacity="0.7"/>
        <circle cx="14" cy="12" r="2.5" fill="#afc9ea" opacity="0.85"/>
        <path d="M10 19.5 C10 16.5 18 16.5 18 19.5" fill="#afc9ea" opacity="0.6"/>
        <path d="M10.5 12 L17.5 12 L16.5 10.5 Q14 9 11.5 10.5 Z" fill="#132030" stroke="#afc9ea" stroke-width="0.4" opacity="0.85"/>
      </svg>
      <div class="sam-logo-text">
        <div class="sam-logo-main">
          Secret Agent Man<span class="paren">(</span><span class="ager">ager</span><span class="paren">)</span>
        </div>
        <div class="sam-logo-sub">TACTICAL AGENT COMMAND</div>
      </div>
    </div>
    <div class="sam-topnav-actions">
      <button class="sam-topnav-btn">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
          <circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>
        </svg>
        SETTINGS
      </button>
      <button class="sam-topnav-btn danger">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
          <circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="2"/>
          <line x1="12" y1="2" x2="12" y2="6"/><line x1="12" y1="18" x2="12" y2="22"/>
          <line x1="2" y1="12" x2="6" y2="12"/><line x1="18" y1="12" x2="22" y2="12"/>
        </svg>
        KILL ALL
      </button>
    </div>
  </nav>

  <%!-- TAB BAR --%>
  <div class="sam-tabs">
    <div
      :for={{id, state} <- @sessions}
      class={"sam-tab #{if id == @selected_session, do: "active"}"}
      phx-click="select_session"
      phx-value-id={id}
    >
      <span class={"status-dot #{status_class(state.status)}"}></span>
      {state.name || id}
    </div>
    <div class="sam-tab-actions">
      <button class="sam-btn-deploy" phx-click="toggle_new_dialog">+ DEPLOY AGENT</button>
    </div>
  </div>

  <%!-- STATUS BAR --%>
  <%= if @selected_session do %>
    <% state = selected_state(@sessions, @selected_session) %>
    <%= if state do %>
      <div class="sam-status-bar">
        <div class="sam-status-left">
          <span class="sam-session-name">{state.name || @selected_session}</span>
          <div class="sam-status-badge">
            <span class={"status-dot #{status_class(state.status)}"}></span>
            {state.status |> to_string() |> String.upcase()}
          </div>
          <span class="sam-status-meta">
            {state[:workdir] || "~"} &bull; {state[:branch] || "no branch"} &bull; {format_uptime(state)}
          </span>
        </div>
        <div class="sam-status-actions">
          <%= if state.status == :needs_input do %>
            <form phx-submit="send_input" class="sam-input-inline">
              <input
                type="text"
                name="input"
                value={@input_text}
                placeholder="Enter response..."
                autofocus
              />
              <button type="button" class="sam-quick-btn" phx-click="quick_respond" phx-value-response="yes">YES</button>
              <button type="button" class="sam-quick-btn" phx-click="quick_respond" phx-value-response="no">NO</button>
              <button type="submit" class="sam-btn-outline">SEND</button>
            </form>
          <% else %>
            <button class="sam-btn-outline" phx-click="toggle_terminal">
              {if @show_terminal, do: "HIDE TTY", else: "SHOW TTY"}
            </button>
            <button class="sam-btn-outline danger" phx-click="kill_session" phx-value-id={@selected_session}>
              TERMINATE
            </button>
          <% end %>
        </div>
      </div>
    <% end %>
  <% end %>

  <%!-- BENTO GRID --%>
  <div class="sam-bento">
    <%!-- TERMINAL (8 cols, spans 2 rows) --%>
    <div class="sam-panel sam-terminal">
      <div class="sam-terminal-indicator">
        <span class="live-dot"></span>
        VIEWING: main
        <span class="live-label">&#9654; LIVE</span>
      </div>
      <div class="sam-terminal-body" id="terminal-container" phx-hook="Terminal" data-session-id={@selected_session}>
      </div>
    </div>

    <%!-- ACTIVITY FEED (4 cols, top right) --%>
    <div class="sam-panel">
      <div class="sam-panel-header">
        <span>ACTIVITY FEED</span>
        <span style="opacity: 0.5;">LIVE</span>
      </div>
      <div class="sam-panel-body">
        <%= if @selected_session do %>
          <% state = selected_state(@sessions, @selected_session) %>
          <%= if state do %>
            <div
              :for={item <- Enum.take(state[:activity] || [], 50)}
              class="activity-item"
            >
              <span class="time">{format_time(item.timestamp)}</span>
              <span class={"msg #{activity_msg_class(item)}"}>{item.text}</span>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>

    <%!-- AGENTS PANEL (4 cols, bottom right) --%>
    <div class="sam-panel">
      <div class="sam-panel-header">
        <span>AGENTS</span>
        <span style="opacity: 0.5;">1 ACTIVE</span>
      </div>
      <div class="sam-panel-body">
        <%= if @selected_session do %>
          <% state = selected_state(@sessions, @selected_session) %>
          <%= if state do %>
            <div class="agent-row selected">
              <div class="agent-row-top">
                <span class={"status-dot #{status_class(state.status)}"}></span>
                <span class="agent-name">main</span>
                <span class="agent-badge">PRIMARY</span>
                <span class={"agent-status #{status_class(state.status)}"}>{state.status |> to_string() |> String.upcase()}</span>
              </div>
              <div class="agent-activity">
                {agent_activity_text(state)}
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
  </div>

  <%!-- FOOTER --%>
  <footer class="sam-footer">
    <span>
      <span class="sam-footer-dot" style="background: var(--phosphor-green);"></span>
      {map_size(@sessions)} SESSIONS &bull; THEME: COMMAND
    </span>
    <span></span>
  </footer>

  <%!-- SESSION CREATION MODAL --%>
  <%= if @show_new_dialog do %>
    <div class="modal-overlay" phx-click="toggle_new_dialog">
      <section class="modal-panel" phx-click-away="toggle_new_dialog">
        <div class="modal-grid-bg"></div>
        <div class="modal-scan"></div>
        <div class="modal-content">
          <div class="modal-header">
            <span class="modal-classified">CLASSIFIED</span>
            <span class="modal-divider"></span>
            <span class="modal-ref">REF: SC-{DateTime.utc_now().year}-XP</span>
          </div>
          <h1 class="modal-title">New Operation</h1>

          <form phx-submit="create_session">
            <div class="modal-field">
              <label class="modal-label">SESSION_IDENTITY</label>
              <input class="modal-input" type="text" name="name" placeholder="ENTER OPERATION CODENAME..." required />
            </div>

            <div class="modal-input-row">
              <div class="modal-field">
                <label class="modal-label">AGENT_SPECIFICATION</label>
                <select class="modal-select" name="agent_type">
                  <option value="claude_code">CLAUDE_CODE</option>
                </select>
              </div>
              <div class="modal-field">
                <label class="modal-label">DEPLOYMENT_VECTOR</label>
                <input class="modal-input" type="text" name="workdir" placeholder="/ROOT/PROJECTS/..." style="font-family: var(--font-mono); font-size: 10px;" />
              </div>
            </div>

            <div class="modal-field">
              <label class="modal-label">INITIAL_DIRECTIVES</label>
              <textarea class="modal-textarea" name="prompt" rows="3" placeholder="DESCRIBE THE TARGET ARCHITECTURE AND OBJECTIVES..."></textarea>
            </div>

            <div class="modal-footer">
              <button type="button" class="modal-abort" phx-click="toggle_new_dialog">
                &#10005; ABORT_MISSION
              </button>
              <div style="display: flex; align-items: center; gap: 12px;">
                <div class="modal-auth">
                  AUTHORIZATION_REQUIRED<br/>
                  <span style="color: rgba(175,201,234,0.5);">LVL_07_ACCESS_GRANTED</span>
                </div>
                <button type="submit" class="modal-submit">
                  &#9656; INITIATE OPERATION
                </button>
              </div>
            </div>
          </form>
        </div>
      </section>
    </div>
  <% end %>
</div>
```

- [ ] **Step 2: Add new event handler and helper functions**

Add a `kill_session` event handler (the TERMINATE button needs it):

```elixir
def handle_event("kill_session", %{"id" => session_id}, socket) do
  Sam.Session.Server.stop(session_id)
  {:noreply, socket}
end
```

**Note:** The SETTINGS and KILL ALL buttons in the top nav are intentionally non-functional in v1 — no `phx-click` handlers. They are structural placeholders for future features.

Add these helper functions to `dashboard_live.ex` (near the existing helpers around lines 139-147):

```elixir
defp format_uptime(%{started_at: started_at}) when not is_nil(started_at) do
  diff = DateTime.diff(DateTime.utc_now(), started_at)
  hours = div(diff, 3600)
  minutes = diff |> rem(3600) |> div(60)
  seconds = rem(diff, 60)
  "#{String.pad_leading(to_string(hours), 2, "0")}:#{String.pad_leading(to_string(minutes), 2, "0")}:#{String.pad_leading(to_string(seconds), 2, "0")}"
end
defp format_uptime(_), do: "00:00:00"

defp agent_activity_text(%{activity: [latest | _]}), do: latest.text
defp agent_activity_text(%{summary: summary}) when is_binary(summary) and summary != "", do: summary
defp agent_activity_text(_), do: "Awaiting directives"

defp activity_msg_class(%{type: :system}), do: "system"
defp activity_msg_class(%{type: :agent_event}), do: "agent-event"
defp activity_msg_class(_), do: ""
```

- [ ] **Step 3: Verify the app compiles**

Run: `mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 4: Verify the dashboard renders in the browser**

Open `http://localhost:4000` and verify:
- Top nav with logo ("Secret Agent Man(ager)") and gear/target icons
- Tab bar with session tabs and "+ DEPLOY AGENT" button
- Status bar with session name, status badge, metadata
- Bento grid: terminal (left), activity feed (top right), agents panel (bottom right)
- Footer at bottom
- CRT scanline overlay visible
- Clicking "+ DEPLOY AGENT" shows the glassmorphism modal

- [ ] **Step 5: Commit**

```bash
git add lib/sam_web/live/dashboard_live.ex
git commit -m "feat: rewrite dashboard template with blue-steel bento grid layout"
```

---

### Task 5: Final Integration & Precommit

**Files:**
- All files from previous tasks

- [ ] **Step 1: Run the full precommit check**

Run: `mix precommit`
Expected: PASS — compile clean (no warnings), format clean, all tests pass.

- [ ] **Step 2: Fix any compilation warnings or test failures**

If `mix precommit` fails, fix the issues. Common things to watch for:
- Unused variables from removed template code
- Missing helper function clauses for edge cases
- Format issues from the template rewrite

- [ ] **Step 3: Manual visual verification**

Open `http://localhost:4000` and verify the complete flow:
- Create a new session via the modal
- Watch the terminal populate with output
- Check status dot animations for different states
- Verify activity feed updates in real-time
- Verify the agents panel shows the main agent with correct status
- Check CRT scanline and glow effects

- [ ] **Step 4: Commit any fixes**

Stage only the specific files that were fixed, then commit:

```bash
git commit -m "fix: address precommit issues from UI redesign"
```
