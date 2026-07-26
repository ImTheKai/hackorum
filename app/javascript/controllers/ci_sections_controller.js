import { Controller } from "@hotwired/stimulus"

// keeps details/summary open state across morph refreshes - server always
// renders open, so without this every broadcast would re-expand collapsed
// sections. content underneath still morphs normally.
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
    const incoming = event.detail.newElement
    if (current.tagName !== "DETAILS" || incoming.tagName !== "DETAILS") return
    incoming.open = current.open
  }
}
