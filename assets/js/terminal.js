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
    // Decode base64 to Uint8Array (not string) to preserve multi-byte UTF-8
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

    // Fit on window resize
    this._resizeHandler = () => this.fitAddon.fit()
    window.addEventListener('resize', this._resizeHandler)

    // Terminal is embedded in bento grid — no escape-to-close needed
  },

  destroyed() {
    if (this.channel) this.channel.leave()
    if (this.term) this.term.dispose()
    if (this._resizeHandler) window.removeEventListener('resize', this._resizeHandler)
  }
}

export default TerminalHook
