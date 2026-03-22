// Body-level tooltip for [data-tooltip] elements.
// Renders a fixed-position div on <body> so it escapes overflow:hidden containers.

let tooltipEl = null
let currentTarget = null

function show(e) {
  const target = e.target.closest("[data-tooltip]")
  if (!target) return

  const text = target.getAttribute("data-tooltip")
  if (!text) return

  currentTarget = target

  if (!tooltipEl) {
    tooltipEl = document.createElement("div")
    tooltipEl.className = "sam-tooltip"
    document.body.appendChild(tooltipEl)
  }

  tooltipEl.textContent = text
  tooltipEl.style.display = "block"
  position(target)
  // Force reflow so the transition triggers
  tooltipEl.offsetHeight
  tooltipEl.classList.add("visible")
}

function hide() {
  currentTarget = null
  if (tooltipEl) {
    tooltipEl.classList.remove("visible")
    tooltipEl.style.display = "none"
  }
}

function position(target) {
  if (!tooltipEl) return

  const rect = target.getBoundingClientRect()
  const tipRect = tooltipEl.getBoundingClientRect()

  let left = rect.left
  let top = rect.bottom + 4

  // Keep within viewport
  if (left + tipRect.width > window.innerWidth - 8) {
    left = window.innerWidth - tipRect.width - 8
  }
  if (left < 8) left = 8

  if (top + tipRect.height > window.innerHeight - 8) {
    top = rect.top - tipRect.height - 4
  }

  tooltipEl.style.left = left + "px"
  tooltipEl.style.top = top + "px"
}

export function initTooltips() {
  document.addEventListener("mouseover", show)
  document.addEventListener("mouseout", (e) => {
    const related = e.relatedTarget
    if (related && related.closest && related.closest("[data-tooltip]") === currentTarget) return
    hide()
  })
}
