import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = { filterSelector: String }

  clickDate(event) {
    event.preventDefault()

    const link = event.currentTarget
    const filterForm = document.querySelector(this.filterSelectorValue)
    const url = new URL(link.href)

    if (filterForm) {
      // carry over whatever the form calls its boxes, so a second filter form
      // with a different param name keeps working
      const checkboxes = filterForm.querySelectorAll('input[type="checkbox"]:checked')
      checkboxes.forEach(checkbox => {
        url.searchParams.append(checkbox.name, checkbox.value)
      })
    }

    const frame = link.dataset.turboFrame
    if (frame) {
      const frameElement = document.getElementById(frame)
      if (frameElement) {
        frameElement.src = url.toString()
        return
      }
    }

    Turbo.visit(url.toString())
  }
}
