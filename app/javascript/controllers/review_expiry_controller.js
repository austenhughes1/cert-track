import { Controller } from "@hotwired/stimulus"

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// The expiry hint on the import review form: what a blank "Expires on" works out to for the
// type and completion date picked right now, kept in step as the reviewer changes them. The
// server renders the same text for the saved choices (ImportsHelper#import_expiry_rule), which
// is what shows without JavaScript. Type options carry data-name and either
// data-validity-months or data-never-expires (ImportsHelper#import_type_option_attributes).
//
//   <form data-controller="review-expiry">
//     <select data-review-expiry-target="type" data-action="change->review-expiry#update">
//       <option value="2" data-name="Flagger" data-validity-months="36">Flagger</option> ...
//     </select>
//     <input type="date" data-review-expiry-target="completed" data-action="input->review-expiry#update">
//     <p>... from the type<span data-review-expiry-target="rule">: Mar 14, 2028 (completed plus 36 months).</span></p>
//   </form>
export default class extends Controller {
  static targets = ["type", "completed", "rule"]

  connect() {
    this.update() // the browser may have restored other choices than the ones rendered
  }

  update() {
    if (this.hasRuleTarget && this.hasTypeTarget) this.ruleTarget.textContent = this.rule()
  }

  rule() {
    const type = this.typeTarget.selectedOptions[0]?.dataset
    if (!type || type.name === undefined) return "."
    if (type.neverExpires !== undefined) return `: ${type.name} never expires.`

    const months = Number(type.validityMonths)
    if (!Number.isInteger(months)) return "."

    const span = `${months} ${months === 1 ? "month" : "months"}`
    const completed = this.hasCompletedTarget ? parseDate(this.completedTarget.value) : null
    if (!completed) return `: completed date plus ${span}.`

    return `: ${formatDate(addMonths(completed, months))} (completed plus ${span}).`
  }
}

// { year, month (1-12), day } from a date field's "YYYY-MM-DD", or null.
function parseDate(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || "")
  return match ? { year: Number(match[1]), month: Number(match[2]), day: Number(match[3]) } : null
}

// Like Ruby's Date#advance(months:): a day past the end of the new month becomes its last day.
function addMonths({ year, month, day }, months) {
  const index = year * 12 + (month - 1) + months
  const newYear = Math.floor(index / 12)
  const newMonth = index - newYear * 12 + 1
  const lastDay = new Date(Date.UTC(newYear, newMonth, 0)).getUTCDate()
  return { year: newYear, month: newMonth, day: Math.min(day, lastDay) }
}

// "Mar 14, 2028", like format_date.
function formatDate({ year, month, day }) {
  return `${MONTHS[month - 1]} ${day}, ${year}`
}
