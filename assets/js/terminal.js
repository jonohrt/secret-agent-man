import '@xterm/xterm/css/xterm.css'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebglAddon } from '@xterm/addon-webgl'
import { Socket } from 'phoenix'

const TerminalHook = {
  mounted() {
    const sessionId = this.el.dataset.sessionId
    const container = this.el.querySelector('#terminal') || this.el

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

    // Connect to Phoenix channel
    const socket = new Socket('/socket', { params: {} })
    socket.connect()

    this.channel = socket.channel(`terminal:${sessionId}`, {})
    this.channel.join()
      .receive('ok', () => {
        console.log(`Connected to terminal:${sessionId}`)
        // Send current terminal size so PTY resizes and redraws
        const dims = this.fitAddon.proposeDimensions()
        if (dims) {
          this.channel.push('resize', { cols: dims.cols, rows: dims.rows })
        }
      })
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

    // Escape to close terminal
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
