// Tabler's native color mode, shared by auth and admin pages.
(() => {
  if (window.helloSMCThemeInitialized) return
  window.helloSMCThemeInitialized = true

  const storageKey = "hellosmc-theme"
  const choices = ["light", "dark"]
  // Without a saved choice, start from the OS appearance once; afterwards only the user's choice counts.
  const fallback = () => (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light")
  const readPreference = () => {
    try {
      const saved = localStorage.getItem(storageKey)
      return choices.includes(saved) ? saved : fallback()
    } catch {
      return fallback()
    }
  }
  let preference = readPreference()

  const applyTheme = () => {
    document.documentElement.setAttribute("data-bs-theme", preference)
    document.documentElement.setAttribute("data-theme-preference", preference)
    document.querySelectorAll("[data-theme-value]").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.themeValue === preference))
    })
  }

  // Delegation survives Turbo body replacements without adding duplicate handlers.
  document.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-theme-value]")
    if (!button || !choices.includes(button.dataset.themeValue)) return
    preference = button.dataset.themeValue
    try {
      localStorage.setItem(storageKey, preference)
    } catch {
      // The selected theme still works when browser storage is unavailable.
    }
    applyTheme()
  })

  document.addEventListener("DOMContentLoaded", applyTheme)
  document.addEventListener("turbo:load", applyTheme)
  document.addEventListener("turbo:before-render", applyTheme)
  window.addEventListener("storage", (event) => {
    if (event.key === storageKey || event.key === null) {
      preference = readPreference()
      applyTheme()
    }
  })
  applyTheme()
})()
