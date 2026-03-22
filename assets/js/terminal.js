import '@xterm/xterm/css/xterm.css'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebglAddon } from '@xterm/addon-webgl'
import { Socket } from 'phoenix'

// Shared socket for all terminal instances
let sharedSocket = null
function getSocket() {
  if (!sharedSocket) {
    sharedSocket = new Socket('/socket', { params: {} })
    sharedSocket.connect()
  }
  return sharedSocket
}

// Persist terminal state across LiveView reconnects.
// When LiveView reconnects (e.g., after Chrome tab throttling kills the
// heartbeat), it destroys and recreates DOM elements. We rescue terminal
// DOM nodes into a hidden container before destruction, then reattach them
// when the new hook mounts.
//
// Key: sessionId → { term, fitAddon, channel, dom }
const terminalCache = {}

// Hidden container that lives outside LiveView's DOM control
let rescueContainer = null
function getRescueContainer() {
  if (!rescueContainer) {
    rescueContainer = document.createElement('div')
    rescueContainer.id = 'terminal-rescue'
    rescueContainer.style.display = 'none'
    document.body.appendChild(rescueContainer)
  }
  return rescueContainer
}

const TerminalHook = {
  mounted() {
    const sessionId = this.el.dataset.sessionId
    const container = this.el

    const cached = terminalCache[sessionId]

    if (cached && cached.dom && cached.channel) {
      // Reattach: move rescued DOM nodes back into the new container
      this.term = cached.term
      this.fitAddon = cached.fitAddon
      this.channel = cached.channel

      // Move all child nodes from the rescue wrapper back into the new container
      while (cached.dom.firstChild) {
        container.appendChild(cached.dom.firstChild)
      }
      cached.dom.remove()
      cached.dom = null

      console.log(`Reattached terminal for ${sessionId} (channel state: ${cached.channel.state})`)

      // Refit in the new container
      requestAnimationFrame(() => {
        this.fitAddon.fit()
      })
    } else if (cached && cached.dom && !cached.channel) {
      // Channel was cleaned up (session died) — rescue DOM but mark as stale
      console.warn(`Terminal ${sessionId}: DOM rescued but channel is gone, cleaning up`)
      cached.dom.remove()
      delete terminalCache[sessionId]
      // Fall through to show empty container — LiveView will remove this element
      // when it discovers the session is gone
    } else if (cached && cached.channel) {
      // Cache exists with live channel but no rescued DOM — this means
      // mounted() fired twice without a destroy cycle. Skip creating a
      // duplicate terminal; the existing one is still alive.
      console.warn(`Terminal ${sessionId}: mounted() called but channel already exists, skipping duplicate`)
      this.term = cached.term
      this.fitAddon = cached.fitAddon
      this.channel = cached.channel
    } else {
      // First mount — create terminal, channel, everything
      this.term = new Terminal({
        theme: {
          background: '#020f1e',
          foreground: '#d6e4f9',
          cursor: '#020f1e',
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
        },
        fontFamily: "'Courier New', 'Menlo', monospace",
        fontSize: 13,
        cursorBlink: false,
      })

      this.fitAddon = new FitAddon()
      this.term.loadAddon(this.fitAddon)
      this.term.open(container)

      try {
        this.term.loadAddon(new WebglAddon())
      } catch (e) {
        console.warn('WebGL addon not available, using canvas renderer')
      }

      // Connect to Phoenix channel
      const socket = getSocket()

      this.channel = socket.channel(`terminal:${sessionId}`, {})
      this.channel.join()
        .receive('ok', () => {
          console.log(`Connected to terminal:${sessionId}`)
          if (this.el.style.display !== 'none') {
            this.fitAddon.fit()
            const dims = this.fitAddon.proposeDimensions()
            if (dims) {
              this.channel.push('resize', { cols: dims.cols, rows: dims.rows })
            }
          }
        })
        .receive('error', (resp) => {
          console.error(`Failed to join terminal:${sessionId}`, resp)
          // Leave the channel to stop the infinite rejoin loop for dead sessions
          this.channel.leave()
          delete terminalCache[sessionId]
        })

      // Log channel error/close events for diagnostics
      this.channel.onError((reason) => {
        console.warn(`Channel error terminal:${sessionId}:`, reason)
      })
      this.channel.onClose(() => {
        console.warn(`Channel closed terminal:${sessionId}`)
      })

      // Terminal input → channel
      this.term.onData((data) => {
        this.channel.push('input', { data })
      })

      // Escape key → send bare ESC byte to interrupt Claude Code
      this.term.attachCustomKeyEventHandler((e) => {
        if (e.key === 'Escape' && e.type === 'keydown') {
          this.channel.push('input', { data: '\x1b' })
          return false
        }
        return true
      })

      // Channel output → terminal
      this.channel.on('output', ({ data }) => {
        const binary = atob(data)
        const bytes = new Uint8Array(binary.length)
        for (let i = 0; i < binary.length; i++) {
          bytes[i] = binary.charCodeAt(i)
        }
        this.term.write(bytes)
      })

      // Handle resize
      this.term.onResize(({ cols, rows }) => {
        this.channel.push('resize', { cols, rows })
      })

      terminalCache[sessionId] = {
        term: this.term,
        fitAddon: this.fitAddon,
        channel: this.channel,
        dom: null,
      }
    }

    // Fit on window resize (only if visible)
    this._resizeHandler = () => {
      if (this.el.style.display !== 'none') {
        this.fitAddon.fit()
      }
    }
    window.addEventListener('resize', this._resizeHandler)

    // Listen for tab selection events
    this._selectHandler = (e) => {
      const selectedId = e.detail.session_id
      if (selectedId === sessionId) {
        this.el.style.display = ''
        requestAnimationFrame(() => {
          this.fitAddon.fit()
          this.term.focus()
        })
      } else {
        this.el.style.display = 'none'
      }
    }
    window.addEventListener('phx:select_terminal', this._selectHandler)

    // Check if this terminal should be visible on initial mount
    const panel = this.el.closest('[data-selected-session]')
    const isSelected = panel && panel.dataset.selectedSession === sessionId
    if (!isSelected) {
      this.el.style.display = 'none'
    } else {
      requestAnimationFrame(() => {
        this.fitAddon.fit()
        this.term.focus()
      })
    }

    // Focus terminal on click so Vimium enters Insert Mode
    container.addEventListener('click', () => this.term.focus())

    // Drag and drop files → paste file path into terminal
    container.addEventListener('dragover', (e) => {
      e.preventDefault()
      e.dataTransfer.dropEffect = 'copy'
    })
    container.addEventListener('drop', (e) => {
      e.preventDefault()
      // Try file:// URIs first (Finder on macOS provides these)
      const uriList = e.dataTransfer.getData('text/uri-list')
      if (uriList && this.channel) {
        const paths = uriList.split('\n')
          .filter(u => u.startsWith('file://'))
          .map(u => decodeURIComponent(new URL(u).pathname))
          .map(p => p.includes(' ') ? `'${p}'` : p)
        if (paths.length > 0) {
          this.channel.push('input', { data: paths.join(' ') })
          return
        }
      }
      // Fallback: plain text (e.g. paths dragged from other apps)
      const text = e.dataTransfer.getData('text/plain')
      if (text && this.channel) {
        this.channel.push('input', { data: text })
      }
    })

    // Window-level ESC handler — works even if xterm doesn't have focus
    // Only send if this terminal is currently visible
    if (!this._escHandler) {
      this._escHandler = (e) => {
        if (e.key === 'Escape' && this.el.style.display !== 'none' && this.channel) {
          this.channel.push('input', { data: '\x1b' })
        }
      }
      window.addEventListener('keydown', this._escHandler, true)
    }
  },

  destroyed() {
    const sessionId = this.el.dataset.sessionId
    const cached = terminalCache[sessionId]

    if (cached) {
      // Rescue xterm DOM nodes into a hidden container outside LiveView's
      // control, so they survive the DOM replacement.
      const wrapper = document.createElement('div')
      wrapper.dataset.rescueSession = sessionId
      while (this.el.firstChild) {
        wrapper.appendChild(this.el.firstChild)
      }
      getRescueContainer().appendChild(wrapper)
      cached.dom = wrapper
      console.log(`Rescued terminal DOM for ${sessionId}`)
    }

    // Clean up event listeners only — terminal and channel stay alive
    if (this._escHandler) window.removeEventListener('keydown', this._escHandler, true)
    if (this._resizeHandler) window.removeEventListener('resize', this._resizeHandler)
    if (this._selectHandler) window.removeEventListener('phx:select_terminal', this._selectHandler)
  }
}

export default TerminalHook
