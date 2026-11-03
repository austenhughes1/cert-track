import { Controller } from "@hotwired/stimulus"

// Requirements editor grid: dims role boxes on rows already required of everyone and
// shows an "Unsaved changes" note once any box differs from how the page loaded.
export default class extends Controller {
  static targets = ["row", "everyoneCell", "roleCell", "status"]

  connect() {
    this.initial = this.#snapshot()
    this.refresh()
  }

  refresh() {
    this.rowTargets.forEach((row) => {
      const everyone = row.querySelector("[data-requirements-grid-target='everyoneCell'] input")
      row.querySelectorAll("[data-requirements-grid-target='roleCell']").forEach((cell) => {
        cell.classList.toggle("opacity-40", everyone.checked)
      })
    })

    if (this.hasStatusTarget) {
      this.statusTarget.classList.toggle("hidden", this.#snapshot() === this.initial)
    }
  }

  #snapshot() {
    return Array.from(this.element.querySelectorAll("input[type=checkbox]"))
      .map((box) => (box.checked ? "1" : "0"))
      .join("")
  }
}
