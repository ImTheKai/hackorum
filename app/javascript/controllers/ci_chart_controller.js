import { Controller } from "@hotwired/stimulus"

// One spec per element, inlined by the server. The only client-side work is
// resolving var(--x) colors: the palette differs per theme, and theme_controller
// stamps data-theme on <html> without dispatching an event, so we watch it.
export default class extends Controller {
  static values = { spec: Object }

  connect() {
    this.generation = 0
    this.theme = document.documentElement.dataset.theme
    this.observer = new MutationObserver(() => {
      // theme_controller rewrites data-theme on every connect, including on
      // Turbo body replacement, and that fires a record even when unchanged
      if (this.theme === document.documentElement.dataset.theme) return
      this.render()
    })
    this.observer.observe(document.documentElement, {
      attributeFilter: ["data-theme"],
    })
    this.render()
  }

  disconnect() {
    this.observer?.disconnect()
    this.sizeObserver?.disconnect()
    this.sizeObserver = null
    this.teardown()
  }

  render() {
    // specs are width: "container", and vega-lite resolves that once at embed
    // time from the element's clientWidth, then only ever recomputes it on
    // window:resize. Embedding into a box-less element - a tab panel still on
    // display: none - pins the chart at zero width for good, so wait instead.
    if (!this.element.clientWidth) {
      this.waitForWidth()
      return
    }

    this.theme = document.documentElement.dataset.theme
    if (typeof vegaEmbed !== "function") {
      this.fail()
      return
    }
    const token = ++this.generation
    this.teardown()

    let spec
    try {
      const style = getComputedStyle(document.documentElement)
      spec = this.resolveVars(this.specValue, style)
    } catch (e) {
      this.fail()
      return
    }

    vegaEmbed(this.element, spec, { actions: false, tooltip: true })
      .then((result) => {
        if (token !== this.generation) {
          result.view.finalize()
          return
        }
        this.element.classList.remove("muted")
        this.result = result
      })
      .catch(() => {
        if (token === this.generation) this.fail()
      })
  }

  // one-shot: a ResizeObserver reports 0x0 while the element has no box and
  // fires again the moment it gets one. Disconnected before rendering so the
  // embedded view's own size changes cannot bounce back in here.
  waitForWidth() {
    if (this.sizeObserver) return
    this.sizeObserver = new ResizeObserver(() => {
      if (!this.element.clientWidth) return
      this.sizeObserver.disconnect()
      this.sizeObserver = null
      this.render()
    })
    this.sizeObserver.observe(this.element)
  }

  // drop the old view before embedding a new one - vegaEmbed owns a canvas,
  // document listeners and a ResizeObserver per view (width is always
  // "container"), and nothing else releases them on re-render or disconnect
  teardown() {
    this.result?.view?.finalize()
    this.result = null
  }

  // walks the whole spec: a var() string can sit in a scale range, a mark fill
  // or a config value, and none of those is worth a separate rule. style is
  // read once per render and threaded through, not re-fetched per var()
  resolveVars(node, style) {
    if (typeof node === "string") return this.resolveVar(node, style)
    if (Array.isArray(node)) return node.map((item) => this.resolveVars(item, style))
    if (node && typeof node === "object") {
      for (const key of Object.keys(node)) node[key] = this.resolveVars(node[key], style)
    }
    return node
  }

  resolveVar(value, style) {
    const match = /^var\((--[\w-]+)\)$/.exec(value)
    if (!match) return value
    const resolved = style.getPropertyValue(match[1]).trim()
    return resolved || value
  }

  fail() {
    this.teardown()
    this.element.textContent = "chart unavailable"
    this.element.classList.add("muted")
  }
}
