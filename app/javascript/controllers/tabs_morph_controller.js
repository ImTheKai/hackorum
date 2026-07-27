import { Controller } from "@hotwired/stimulus"

// keeps the selected tab across morph refreshes - the server renders a fixed
// tab active, so without this every broadcast would jump back to it. Panel
// content underneath still morphs normally.
export default class extends Controller {
  connect() {
    this.onBeforeMorphElement = this.handleBeforeMorphElement.bind(this)
    this.element.addEventListener("turbo:before-morph-element", this.onBeforeMorphElement)
  }

  disconnect() {
    this.element.removeEventListener("turbo:before-morph-element", this.onBeforeMorphElement)
  }

  handleBeforeMorphElement(event) {
    const current = event.target
    if (!current.hasAttribute("data-tabs-target")) return

    const incoming = event.detail.newElement
    incoming.classList.toggle("is-active", current.classList.contains("is-active"))
    if (current.hasAttribute("aria-selected")) {
      incoming.setAttribute("aria-selected", current.getAttribute("aria-selected"))
    }
  }
}
