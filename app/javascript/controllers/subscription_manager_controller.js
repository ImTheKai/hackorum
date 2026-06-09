import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox", "batchButton"]

  connect() {
    this.updateBatchButton()
  }

  toggleAll() {
    const anyUnchecked = this.checkboxTargets.some(cb => !cb.checked)
    this.checkboxTargets.forEach(cb => { cb.checked = anyUnchecked })
    this.updateBatchButton()
  }

  toggle() {
    this.updateBatchButton()
  }

  updateBatchButton() {
    const anyChecked = this.checkboxTargets.some(cb => cb.checked)
    this.batchButtonTarget.disabled = !anyChecked
  }
}
