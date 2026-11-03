import { Controller } from "@hotwired/stimulus"

// Reloads the current page through Turbo after a delay, for as long as the element is on the
// page (e.g. while a background job builds something). Leaving the page cancels the timer.
//
//   <section data-controller="auto-refresh" data-auto-refresh-interval-value="3000">
export default class extends Controller {
  static values = { interval: { type: Number, default: 3000 } }

  connect() {
    this.timeout = setTimeout(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    clearTimeout(this.timeout)
  }

  refresh() {
    window.Turbo.visit(window.location.href, { action: "replace" })
  }
}
