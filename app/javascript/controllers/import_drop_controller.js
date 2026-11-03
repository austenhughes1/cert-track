import FileDropController from "controllers/file_drop_controller"

// file-drop for the Imports screen: many files and zips in one batch. The limit is on the
// batch (maxBytes is the 500 MB batch total, maxFiles the entry cap), not per file, and the
// summary line shows how much of it is used. Uploading, progress and removal are file-drop's.
//
//   <div data-controller="import-drop" data-import-drop-max-bytes-value="524288000"
//        data-import-drop-max-files-value="2000" data-import-drop-extensions-value='["pdf","zip"]' ...>
//     ... the file-drop targets ...
//     <p data-import-drop-target="summary" hidden></p>
//   </div>
export default class extends FileDropController {
  static targets = ["summary"]
  static values = { maxFiles: Number }

  problemWith(file) {
    if (this.files.some((existing) => sameFile(existing, file))) return null // already listed; file-drop skips it

    const extension = file.name.includes(".") ? file.name.split(".").pop().toLowerCase() : ""
    if (!this.extensionsValue.includes(extension)) return "is not a PDF, JPG, PNG, HEIC, WEBP or zip file."
    if (file.size === 0) return "is empty."
    if (this.maxFilesValue && this.files.length >= this.maxFilesValue) {
      return `would go past ${this.maxFilesValue} files; import it in another batch.`
    }
    if (this.totalBytes() + file.size > this.maxBytesValue) {
      return `would take the batch past ${formatBytes(this.maxBytesValue)}; import it in another batch.`
    }
    return null
  }

  render() {
    super.render()
    if (!this.hasSummaryTarget) return

    const count = this.files.length
    this.summaryTarget.hidden = count === 0
    this.summaryTarget.textContent =
      `${count} ${count === 1 ? "file" : "files"}, ${formatBytes(this.totalBytes())} of ${formatBytes(this.maxBytesValue)}`
  }

  totalBytes() {
    return this.files.reduce((sum, file) => sum + file.size, 0)
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
