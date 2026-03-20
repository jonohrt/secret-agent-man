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
