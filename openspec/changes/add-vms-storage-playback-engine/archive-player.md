# Per-camera archive player

The recordings page is separate from live viewing. It uses the same fresh
recording permission and scoped Source reads as the archive API; opening it does
not acquire a live relay. Inventory pages replace the visible candidates instead
of growing an unbounded list. Each page may be empty with a continuation cursor.
A recording selection and each later media request are independently authorized.

Publication time labels publication only. Capture UTC remains unknown. Playback
controls seek within one finite selected window, with explicit window navigation;
they do not promise a full recording, cross-block continuity or a capture-time
timeline. The existing playlist serializer owns the fragment, duration and byte
limits. Metadata and a previously fetched playlist never grant later access.

The browser uses exactly pinned `hls.js` 1.7.3 through its light build, bundled in
the normal application assets. It handles playlist parsing and MediaSource
seeking; the live Annex-B player remains independent. The archive hook uses
native video controls and no autoplay. Browsers without the required MediaSource
support get an unsupported message; native HLS fallback remains unqualified.
The library's optional worker is disabled for this bounded CMAF path, avoiding
an additional worker asset and policy surface. Audio, HEVC and broader browser
support remain separate qualification gates.

Each started playlist or fragment request has a 12-second first-byte and total-load
limit, with no automatic network retry. Forward and back buffering target
eight seconds, but whole fragments can exceed that duration. These are not
hard memory limits; the server separately bounds individual resource bytes and
finite playlist windows. The targets are engineering choices, not measured
production capacity objectives. A fatal error destroys the client, clears old
video and offers an explicit retry that starts a fresh authorized request.

The current isolated reader admits one request at a time. The client serializes
its initialization and media fragment requests through the HLS loader interface;
queued requests can be cancelled before they issue HTTP. Queue time is separate
from the per-request deadline. Cancelling a browser
request does not prove its server/provider work has retired. A quick recording
switch or seek that aborts an in-flight read can therefore receive a busy response; the player reports unavailability
and lets the operator retry after the previous read completes. Retry starts fresh
playback; it does not restore the interrupted seek position. This checkpoint
does not enlarge admission or add a parallel provider reader. Destruction,
pagehide and LiveView disconnection abort client work and clear the video;
reconnection or restoration from the browser page cache starts a fresh load.

## Validation boundaries

The default remote test set includes the production hook in real Chromium,
generated synthetic CMAF, finite playlists and a controlled HTTP server. It
checks decoded frame colors after seeks and recording switches, explicit recovery
after an interrupted seek meets a busy reader, complete
non-Range requests, session-cookie delivery, denied reads, deadlines, explicit
retry and teardown/recovery. The controlled server does not prove product
RBAC, database publication or actual provider cancellation.

Those contracts belong to the existing joined Web database owner. Its public
HTTP cancellation case holds a real provider GET, closes the public client,
checks refusal without more provider work, then verifies eventual admission,
exact fragment bytes and unchanged publication. Final published-head Core/Web
execution and successful fixture cleanup remain mandatory. No live rollout,
recording enablement or hosted provider qualification is implied.
