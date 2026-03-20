const THEMES = ['tron', 'synthwave', 'phosphor', 'amber']
const STORAGE_KEY = 'sam-theme'

export function initTheme() {
  const saved = localStorage.getItem(STORAGE_KEY) || 'tron'
  applyTheme(saved)
}

export function cycleTheme() {
  const current = getCurrentTheme()
  const idx = THEMES.indexOf(current)
  const next = THEMES[(idx + 1) % THEMES.length]
  applyTheme(next)
  return next
}

export function applyTheme(name) {
  document.body.className = `theme-${name}`
  localStorage.setItem(STORAGE_KEY, name)
}

export function getCurrentTheme() {
  return localStorage.getItem(STORAGE_KEY) || 'tron'
}

document.addEventListener('keydown', (e) => {
  if (e.ctrlKey && e.key === 't') {
    e.preventDefault()
    cycleTheme()
  }
})
