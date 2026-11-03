import { Controller } from "@hotwired/stimulus"

// "Add a crew member" form: says which role's requirements will apply, the project
// role override when one is chosen, else the selected member's own role.
export default class extends Controller {
  static targets = ["member", "role", "hint"]

  connect() {
    this.update()
  }

  update() {
    this.hintTarget.textContent = this.#describe()
  }

  #describe() {
    if (this.roleTarget.value) {
      return `${this.roleTarget.selectedOptions[0].text} (project role)`
    }
    if (!this.memberTarget.value) {
      return "the member's role"
    }
    const memberRole = this.memberTarget.selectedOptions[0].dataset.role
    return memberRole ? `${memberRole} (member's role)` : "no role: only requirements for everyone apply"
  }
}
