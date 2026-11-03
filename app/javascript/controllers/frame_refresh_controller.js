import AutoRefreshController from "controllers/auto_refresh_controller"

// auto-refresh for part of a page: reloads only the enclosing <turbo-frame> from the current
// URL, so scroll position and anything picked or typed outside the frame survive. The server
// re-renders the frame; once its content no longer carries this controller, refreshing stops.
// Outside a frame it falls back to auto-refresh's whole-page reload.
//
//   <turbo-frame id="batch_progress" target="_top">
//     <div data-controller="frame-refresh" data-frame-refresh-interval-value="3000"> ... </div>
//   </turbo-frame>
export default class extends AutoRefreshController {
  refresh() {
    const frame = this.element.closest("turbo-frame")
    if (!frame) return super.refresh()

    if (frame.src) {
      frame.reload()
    } else {
      frame.src = window.location.href
    }
  }
}
