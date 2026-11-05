import { Controller } from "@hotwired/stimulus"

// The issuer picker (shared/_issuer_picker): the "new issuer's name" field shows, and is
// required, only while "Other…" (value "other") is chosen. Hidden, it is also disabled so a
// name typed earlier isn't sent with another choice. Without JavaScript the field stays
// visible, and its hint says it is only used with "Other…".
//
//   <div data-controller="issuer-picker">
//     <select data-issuer-picker-target="select" data-action="change->issuer-picker#toggle">
//       ... <option value="other">Other…</option>
//     </select>
//     <div data-issuer-picker-target="other">
//       <input data-issuer-picker-target="name">
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
