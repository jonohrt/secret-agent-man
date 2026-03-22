// assets/js/notifications.js
const NotificationsHook = {
  mounted() {
    this.permissionGranted = false
    this.soundEnabled = localStorage.getItem("sam-sound-enabled") === "true"
    // Sync button opacity with initial state
    const soundBtn = document.getElementById("sound-btn")
    if (soundBtn) soundBtn.style.opacity = this.soundEnabled ? "1" : "0.4"
    this.audioCtx = null

    // Request notification permission
    if ("Notification" in window && Notification.permission === "default") {
      Notification.requestPermission().then(perm => {
        this.permissionGranted = perm === "granted"
      })
    } else if ("Notification" in window) {
      this.permissionGranted = Notification.permission === "granted"
    }

    // Sound toggle (capture this for window-scoped callback)
    const self = this
    window.samToggleSound = (btn) => {
      self.soundEnabled = !self.soundEnabled
      localStorage.setItem("sam-sound-enabled", self.soundEnabled)
      btn.style.opacity = self.soundEnabled ? "1" : "0.4"
    }

    // Handle notify push events from LiveView
    this.handleEvent("notify", ({ status, session_name, session_id }) => {
      const messages = {
        needs_input: "Waiting for input",
        done: "Session completed",
        error: "Session error"
      }
      const message = messages[status] || status

      // Toast (always shown)
      this.showToast(status, session_name, message)

      // Browser notification (only when tab not focused)
      if (!document.hasFocus() && this.permissionGranted) {
        new Notification(`SAM: ${session_name}`, { body: message, tag: session_id })
      }

      // Sound (needs_input and error only)
      if (this.soundEnabled && (status === "needs_input" || status === "error")) {
        this.playChime()
      }
    })
  },

  showToast(status, name, message) {
    let container = document.getElementById("sam-toast-container")
    if (!container) {
      container = document.createElement("div")
      container.id = "sam-toast-container"
      container.style.cssText = "position:fixed;top:1rem;right:1rem;z-index:9999;display:flex;flex-direction:column;gap:0.5rem;pointer-events:none;"
      document.body.appendChild(container)
    }

    const colors = {
      needs_input: "var(--status-input)",
      done: "var(--status-done)",
      error: "var(--status-error)"
    }
    const color = colors[status] || "var(--outline)"

    const toast = document.createElement("div")
    toast.style.cssText = `background:var(--surface-dim);border:1px solid ${color};border-radius:8px;padding:0.75rem 1rem;display:flex;align-items:center;gap:0.75rem;box-shadow:0 4px 12px rgba(0,0,0,0.4);pointer-events:auto;min-width:200px;`
    toast.innerHTML = `
      <div style="width:10px;height:10px;border-radius:50%;background:${color};box-shadow:0 0 6px ${color};flex-shrink:0;"></div>
      <div style="flex:1;">
        <div style="color:var(--on-surface);font-size:0.85rem;font-weight:500;">${this.escapeHtml(name)}</div>
        <div style="color:${color};font-size:0.75rem;">${this.escapeHtml(message)}</div>
      </div>
      <div style="color:var(--outline);cursor:pointer;font-size:0.75rem;padding:0.25rem;" onclick="this.parentElement.remove()">&#10005;</div>
    `
    container.appendChild(toast)
    setTimeout(() => toast.remove(), 5000)
  },

  playChime() {
    try {
      const ctx = this.audioCtx || new (window.AudioContext || window.webkitAudioContext)()
      this.audioCtx = ctx
      const osc = ctx.createOscillator()
      const gain = ctx.createGain()
      osc.connect(gain)
      gain.connect(ctx.destination)
      osc.type = "sine"
      osc.frequency.setValueAtTime(880, ctx.currentTime)
      osc.frequency.setValueAtTime(1100, ctx.currentTime + 0.1)
      gain.gain.setValueAtTime(0.1, ctx.currentTime)
      gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.2)
      osc.start(ctx.currentTime)
      osc.stop(ctx.currentTime + 0.2)
    } catch (_) {
      // Autoplay policy may block — silently fail
    }
  },

  escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }
}

export default NotificationsHook
