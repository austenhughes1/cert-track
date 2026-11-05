import { Controller } from "@hotwired/stimulus"

// A picker with "Other…" (the issuer and certificate type pickers): the field for the new
// record's name shows, and is required, only while "Other…" (value "other") is chosen. Hidden, it is also disabled so a
// name typed earlier isn't sent with another choice. Without JavaScript the field stays
// visible, and its hint says it is only used with "Other…".
//
//   <div data-controller="other-choice">
//     <select data-other-choice-target="select" data-action="change->other-choice#toggle">
//       ... <option value="other">Other…</option>
//     </select>
//     <div data-other-choice-target="other">
//       <input data-other-choice-target="name">
//     </div>
//   </div>
export default class extends Controller {
  static targets = ["select", "other", "name"]

  connect() {
    this.toggle() // the browser may have restored another choice than the one rendered
  }

  toggle() {
    const other = this.selectTarget.value === "other"
    this.otherTarget.hidden = !other
    this.nameTarget.disabled = !other
    this.nameTarget.required = other
  }
}
