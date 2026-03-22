import '@xterm/xterm/css/xterm.css'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebglAddon } from '@xterm/addon-webgl'
import { Socket } from 'phoenix'

const AuxTerminalHook = {
  mounted() {
    const sessionId = this.el.dataset.sessionId
    const workdir = this.el.dataset.workdir

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
    this.term.open(this.el)

    try {
      this.term.loadAddon(new WebglAddon())
    } catch (e) {
      console.warn('WebGL addon not available, using canvas renderer')
    }

    // Fit after a frame so the container has dimensions
    requestAnimationFrame(() => {
      this.fitAddon.fit()
    })

    // Re-fit when the container becomes visible or resizes
    this._resizeObserver = new ResizeObserver(() => {
      this.fitAddon.fit()
    })
    this._resizeObserver.observe(this.el)

    // Connect to Phoenix channel
    const socket = new Socket('/socket', { params: {} })
    socket.connect()

    this.channel = socket.channel(`aux_terminal:${sessionId}`, { workdir })
    this.channel.join()
      .receive('ok', () => {
        const dims = this.fitAddon.proposeDimensions()
        if (dims) {
          this.channel.push('resize', { cols: dims.cols, rows: dims.rows })
        }
      })
      .receive('error', (resp) => console.error('Failed to join aux terminal', resp))

    // Terminal input → channel
    this.term.onData((data) => {
      this.channel.push('input', { data })
    })

    // Channel output → terminal (base64 → Uint8Array)
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

    // Drag and drop files → paste file path into terminal
    this.el.addEventListener('dragover', (e) => {
      e.preventDefault()
      e.dataTransfer.dropEffect = 'copy'
    })
    this.el.addEventListener('drop', (e) => {
      e.preventDefault()
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
      const text = e.dataTransfer.getData('text/plain')
      if (text && this.channel) {
        this.channel.push('input', { data: text })
      }
    })
  },

  destroyed() {
    if (this._resizeObserver) this._resizeObserver.disconnect()
    if (this.channel) this.channel.leave()
    if (this.term) this.term.dispose()
    if (this._resizeHandler) window.removeEventListener('resize', this._resizeHandler)
  }
}

export default AuxTerminalHook
