import { Controller } from "@hotwired/stimulus"

const KEYS = { a: "accept", r: "reject", s: "skip" }

// Keyboard shortcuts on the import review screen: a = accept, r = reject, s = skip, in either
// case (Caps Lock). Each clicks its button, so the button's own form (and any edits in it) is
// what gets submitted. Keys typed into a field, with a modifier (Shift included), or held down
// are ignored, and so is everything while one of the screen's forms is submitting.
//
//   <div data-controller="review-shortcuts"
//        data-action="keydown@document->review-shortcuts#press
//                     turbo:submit-start->review-shortcuts#started turbo:submit-end->review-shortcuts#ended">
//     <button data-review-shortcuts-target="accept">Accept</button> ...
//   </div>
export default class extends Controller {
  static targets = ["accept", "reject", "skip"]

  connect() {
    this.submitting = false
  }

  started() {
    this.submitting = true
  }

  ended() {
    this.submitting = false
  }

  press(event) {
    if (this.submitting || event.defaultPrevented || event.repeat) return
    if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return
    if (typing(event.target)) return

    const name = KEYS[(event.key || "").toLowerCase()]
    if (!name || !this[`has${capitalize(name)}Target`]) return

    const button = this[`${name}Target`]
    if (button.disabled) return

    event.preventDefault()
    button.click()
  }
}

function typing(element) {
  return element instanceof Element &&
    element.closest("input, textarea, select, [contenteditable]:not([contenteditable='false']), dialog[open]") !== null
}

function capitalize(word) {
  return word.charAt(0).toUpperCase() + word.slice(1)
}
