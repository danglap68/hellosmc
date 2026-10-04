// Tabler's native color mode, shared by auth and admin pages.
(() => {
  if (window.helloSMCThemeInitialized) return
  window.helloSMCThemeInitialized = true

  const storageKey = "hellosmc-theme"
  const systemTheme = window.matchMedia("(prefers-color-scheme: dark)")
  const choices = ["light", "dark", "system"]
  const readPreference = () => {
    try {
      const saved = localStorage.getItem(storageKey)
      return choices.includes(saved) ? saved : "system"
    } catch {
      return "system"
    }
  }
  let preference = readPreference()

  const applyTheme = () => {
    const theme = preference === "system" ? (systemTheme.matches ? "dark" : "light") : preference
    document.documentElement.setAttribute("data-bs-theme", theme)
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
  systemTheme.addEventListener("change", () => {
    if (preference === "system") applyTheme()
  })
  window.addEventListener("storage", (event) => {
    if (event.key === storageKey || event.key === null) {
      preference = readPreference()
      applyTheme()
    }
  })
  applyTheme()
})()
