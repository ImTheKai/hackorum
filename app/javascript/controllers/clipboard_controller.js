import { Controller } from "@hotwired/stimulus"

// Copies a provided URL to the clipboard.
export default class extends Controller {
  static values = { url: String }

  async copy(event) {
    event.preventDefault()
    const text = this.urlValue
    if (!text) return

    try {
      await navigator.clipboard.writeText(text)
    } catch (_err) {
      this.fallbackCopy(text)
    }

    this.showFeedback()
  }

  fallbackCopy(text) {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.setAttribute("readonly", "")
    textarea.style.position = "absolute"
    textarea.style.left = "-9999px"
    document.body.appendChild(textarea)
    textarea.select()
    document.execCommand("copy")
    textarea.remove()
  }

  showFeedback() {
    this.element.classList.add("copied")
    setTimeout(() => this.element.classList.remove("copied"), 1200)
  }
}
