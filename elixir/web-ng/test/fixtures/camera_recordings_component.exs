alias ServiceRadarWebNGWeb.CameraLive.RecordingsComponents
alias ServiceRadarWebNGWeb.Endpoint

# Verified routes read Endpoint configuration; no HTTP server or ServiceRadar app is started.
Application.put_env(:serviceradar_web_ng, Endpoint,
  server: false,
  secret_key_base: String.duplicate("synthetic-component-key-", 4),
  url: [host: "example.test"],
  live_view: [signing_salt: "synthetic-component-salt"]
)

{:ok, _} = Application.ensure_all_started(:phoenix)
{:ok, endpoint} = Endpoint.start_link()

source_id = "11111111-1111-4111-8111-111111111111"
block_id = "22222222-2222-4222-8222-222222222222"
published_at = "2100-01-01T12:00:00Z"

assigns = %{
  __changed__: nil,
  source: %{id: source_id, device_uid: "sr:synthetic-archive-camera", display_name: "Example gate camera"},
  items: Enum.map([block_id, "33333333-3333-4333-8333-333333333333"], &%{block_id: &1, published_at: published_at}),
  next_cursor: nil,
  selected: %{
    block_id: block_id,
    window: %{index: 0, total: 1, first: 0, count: 3, duration_ns: 6_000_000_000},
    playlist_path: "/api/cameras/#{source_id}/recordings/#{block_id}/playlist.m3u8?first=0&count=3"
  },
  error: nil,
  loading: false,
  timezone: "Etc/UTC"
}

html = assigns |> RecordingsComponents.recordings() |> Phoenix.HTML.Safe.to_iodata()

File.write!(hd(System.argv()), [
  ~s(<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/app.css"><title>Camera recordings component</title></head><body>),
  html,
  "</body></html>"
])

Supervisor.stop(endpoint)
