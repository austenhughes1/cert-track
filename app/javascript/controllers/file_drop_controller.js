import { Controller } from "@hotwired/stimulus"

const HIGHLIGHT = ["border-blue-500", "bg-blue-50"]

// Drag-and-drop for a multiple, direct-upload file field (form.file_field ..., direct_upload: true).
// Keeps everything picked so far (the native picker replaces its selection on each use),
// turns away disallowed types and sizes before anything uploads, and shows per-file progress
// from Active Storage's direct-upload:* events, which bubble up from the input.
//
//   <div data-controller="file-drop" data-file-drop-max-bytes-value="26214400"
//        data-file-drop-extensions-value='["pdf","jpg"]'
//        data-action="drop->file-drop#drop dragover->file-drop#dragOver dragleave->file-drop#dragLeave
//                     direct-upload:progress->file-drop#uploadProgress ...">
//     <div data-file-drop-target="zone"> <input type="file" multiple data-file-drop-target="input"
//          data-action="change->file-drop#select"> </div>
//     <p data-file-drop-target="message" hidden></p>
//     <ul data-file-drop-target="list"></ul>
//   </div>
export default class extends Controller {
  static targets = ["input", "zone", "list", "message"]
  static values = { maxBytes: Number, extensions: Array }

  connect() {
    this.files = []
    this.rows = []
  }

  select() {
    this.add(Array.from(this.inputTarget.files))
  }

  dragOver(event) {
    if (!this.carriesFiles(event)) return

    event.preventDefault()
    event.dataTransfer.dropEffect = "copy"
    this.zoneTarget.classList.add(...HIGHLIGHT)
  }

  dragLeave(event) {
    if (!this.element.contains(event.relatedTarget)) this.zoneTarget.classList.remove(...HIGHLIGHT)
  }

  drop(event) {
    if (!this.carriesFiles(event)) return

    event.preventDefault()
    this.zoneTarget.classList.remove(...HIGHLIGHT)
    if (this.inputTarget.disabled) return

    this.add(Array.from(event.dataTransfer.files))
  }

  remove(event) {
    this.files.splice(Number(event.params.index), 1)
    this.sync()
  }

  // Active Storage creates one upload per file, in input order, when the form is submitted.
  uploadInitialize(event) {
    const { id, file } = event.detail
    const row = this.rows.find((candidate) => !candidate.uploadId && sameFile(candidate.file, file))
    if (!row) return

    row.uploadId = id
    row.removeButton.remove()
    this.setStatus(row, "Waiting…")
  }

  uploadStart(event) {
    this.withRow(event, (row) => this.setStatus(row, "Uploading…"))
  }

  uploadProgress(event) {
    this.withRow(event, (row) => {
      const percent = Math.round(event.detail.progress)
      row.bar.style.width = `${percent}%`
      this.setStatus(row, `${percent}%`)
    })
  }

  // Shown on the row instead of Active Storage's default alert(); the form stays editable to retry.
  uploadError(event) {
    event.preventDefault()
    this.withRow(event, (row) => {
      row.bar.classList.replace("bg-blue-600", "bg-red-600")
      this.setStatus(row, `Failed: ${event.detail.error}`, "text-red-700")
    })
  }

  uploadEnd(event) {
    this.withRow(event, (row) => {
      if (row.status.classList.contains("text-red-700")) return

      row.bar.style.width = "100%"
      this.setStatus(row, "Uploaded", "text-green-700")
    })
  }

  // private

  add(picked) {
    const problems = []
    for (const file of picked) {
      const problem = this.problemWith(file)
      if (problem) {
        problems.push(`${file.name} ${problem}`)
      } else if (!this.files.some((existing) => sameFile(existing, file))) {
        this.files.push(file)
      }
    }
    this.showMessage(problems)
    this.sync()
  }

  problemWith(file) {
    const extension = file.name.includes(".") ? file.name.split(".").pop().toLowerCase() : ""
    if (!this.extensionsValue.includes(extension)) return "is not a PDF, JPG, PNG, HEIC or WEBP file."
    if (file.size > this.maxBytesValue) return `is larger than ${formatBytes(this.maxBytesValue)}.`
    if (file.size === 0) return "is empty."
    return null
  }

  // Puts the kept files back on the input, which is what the form actually submits.
  sync() {
    const transfer = new DataTransfer()
    this.files.forEach((file) => transfer.items.add(file))
    this.inputTarget.files = transfer.files
    this.render()
  }

  render() {
    this.listTarget.replaceChildren()
    this.rows = this.files.map((file, index) => {
      const row = document.createElement("li")
      row.className = "rounded-md border border-gray-200 bg-white px-3 py-2 text-sm"

      const line = document.createElement("div")
      line.className = "flex items-center justify-between gap-3"
      const name = document.createElement("span")
      name.className = "truncate text-gray-900"
      name.textContent = file.name
      const meta = document.createElement("span")
      meta.className = "flex shrink-0 items-center gap-3 text-xs text-gray-500"
      const status = document.createElement("span")
      status.textContent = formatBytes(file.size)
      const removeButton = document.createElement("button")
      removeButton.type = "button"
      removeButton.className = "cursor-pointer text-red-700 hover:underline"
      removeButton.textContent = "Remove"
      removeButton.setAttribute("aria-label", `Remove ${file.name}`)
      removeButton.dataset.action = "file-drop#remove"
      removeButton.dataset.fileDropIndexParam = index
      meta.append(status, removeButton)
      line.append(name, meta)

      const track = document.createElement("div")
      track.className = "mt-1.5 h-1 overflow-hidden rounded bg-gray-100"
      const bar = document.createElement("div")
      bar.className = "h-full bg-blue-600 transition-all"
      bar.style.width = "0%"
      track.append(bar)

      row.append(line, track)
      this.listTarget.append(row)
      return { file, status, bar, removeButton, uploadId: null }
    })
  }

  setStatus(row, text, colorClass = "text-gray-500") {
    row.status.textContent = text
    row.status.className = colorClass
  }

  withRow(event, callback) {
    const row = this.rows.find((candidate) => candidate.uploadId === event.detail.id)
    if (row) callback(row)
  }

  showMessage(problems) {
    this.messageTarget.textContent = problems.length ? `Not added: ${problems.join(" ")}` : ""
    this.messageTarget.hidden = problems.length === 0
  }

  carriesFiles(event) {
    return Array.from(event.dataTransfer?.types || []).includes("Files")
  }
}

function sameFile(a, b) {
  return a.name === b.name && a.size === b.size && a.lastModified === b.lastModified
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  const megabytes = bytes / (1024 * 1024)
  return `${Number.isInteger(megabytes) ? megabytes : megabytes.toFixed(1)} MB`
}
