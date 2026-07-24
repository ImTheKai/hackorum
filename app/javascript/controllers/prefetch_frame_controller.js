import { Controller } from "@hotwired/stimulus"

// Loads a lazy turbo-frame before it scrolls into view. Turbo's own lazy
// observer has no rootMargin, so it only fires once the frame is visible.
export default class extends Controller {
  static values = {
    margin: { type: Number, default: 150 }
  }

  connect() {
    if (!this.element.getAttribute("src")) return
    if (this.element.hasAttribute("complete") || this.element.hasAttribute("busy")) return

    this.observer = new IntersectionObserver(
      entries => {
        if (entries.some(entry => entry.isIntersecting)) this.load()
      },
      { rootMargin: `${this.marginValue}% 0px` }
    )
    this.observer.observe(this.element)
  }

  disconnect() {
    this.observer?.disconnect()
    this.observer = null
  }

  load() {
    this.observer?.disconnect()
    this.observer = null
    this.element.setAttribute("loading", "eager")
  }
}
