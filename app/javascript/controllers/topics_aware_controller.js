import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    awareUrl: String,
    awareAllUrl: String,
  }

  markVisibleAware(event) {
    event.preventDefault()
    const rows = Array.from(document.querySelectorAll("[data-topic-id][data-last-message-id]"))
    const payload = rows.map(row => ({
      topic_id: Number(row.dataset.topicId),
      up_to_message_id: Number(row.dataset.lastMessageId),
    })).filter(entry => entry.topic_id && entry.up_to_message_id)

    if (payload.length === 0) return

    fetch(this.awareUrlValue, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...this.csrfHeaders(),
      },
      body: JSON.stringify({ topics: payload }),
    }).then(resp => {
      if (resp.ok) {
        rows.forEach(row => this.markRowAware(row))
      }
    }).catch(e => console.warn("mark visible aware failed", e))
  }

  markAllAware(event) {
    event.preventDefault()
    if (!window.confirm("Mark ALL threads as aware up to now? This will clear the 'New' status everywhere.")) {
      return
    }
    fetch(this.awareAllUrlValue, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...this.csrfHeaders(),
      },
      body: JSON.stringify({ before: new Date().toISOString() }),
    }).then(resp => {
      if (resp.ok) {
        document.querySelectorAll(".status-pill").forEach(pill => {
          pill.classList.remove("is-new", "is-reading", "is-read")
          pill.classList.add("is-aware")
          pill.textContent = "Aware"
        })
      }
    }).catch(e => console.warn("mark all aware failed", e))
  }

  csrfHeaders() {
    const token = document.querySelector("meta[name=csrf-token]")?.content
    return token ? { "X-CSRF-Token": token } : {}
  }

  markRowAware(row) {
    const pill = row.querySelector(".status-pill")
    if (!pill) return
    pill.classList.remove("is-new", "is-reading", "is-read")
    pill.classList.add("is-aware")
    pill.textContent = "Aware"
  }
}
