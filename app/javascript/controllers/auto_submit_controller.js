import { Controller } from "@hotwired/stimulus"

// Submits its form while the user types (debounced) or changes a select.
//
//   <form data-controller="auto-submit" data-turbo-frame="results" data-auto-submit-delay-value="300">
//     <input type="search" data-action="input->auto-submit#debouncedSubmit">
//     <select data-action="change->auto-submit#submit">
//
// Point the form at a Turbo Frame so the inputs keep focus while results refresh.
export default class extends Controller {
  static values = { delay: { type: Number, default: 300 } }

  disconnect() {
    clearTimeout(this.timeout)
  }

  debouncedSubmit() {
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.submit(), this.delayValue)
  }

  submit() {
    clearTimeout(this.timeout)
    this.element.requestSubmit()
  }
}
