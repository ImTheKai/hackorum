import { Controller } from "@hotwired/stimulus"

// Auto-refresh the page once after a short delay so a still-sending draft
// gets re-rendered with its final state (destroyed on success, idle+error
// on permanent failure). One-shot, not a polling loop.
export default class extends Controller {
  connect() {
    this.timer = setTimeout(() => window.location.reload(), 3000)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
