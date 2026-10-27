import CameraArchivePlayer from "./js/hooks/CameraArchivePlayer"

// Exercise the shipped hook lifecycle; this harness supplies DOM and HTTP bytes,
// not a second player or the product's authorization/storage implementation.
const hook = {...CameraArchivePlayer, el: document.querySelector("[phx-hook='CameraArchivePlayer']")}
hook.mounted()
window.archiveHook = hook
