defmodule ServiceRadarNVR.ReadListener do
  @moduledoc """
  Opt-in private TLS listener that serves recorded media to web-ng for playback.

  It is separate from the ingest listener: its own port, client certificate pin
  and read-purpose bearer token, so a playback credential can neither record nor
  archive, and an ingest credential cannot read media. `ServiceRadarNVR.Config`
  refuses a read installation that shares the ingest port, pin or token.
  Requests run in the playback read pool (`ServiceRadarNVR.Reads`).
  """

  alias ServiceRadarNVR.ListenerConfig

  def load(env) do
    ListenerConfig.load(
      env,
      "SERVICERADAR_NVR_READ_CONFIG_FILE",
      "SERVICERADAR_NVR_READ_TOKEN_FILE",
      :invalid_nvr_read_config
    )
  end

  # Connections beyond the read slots are answered 503 by the pool, not left
  # waiting in the acceptor queue.
  def child_spec(config) do
    ListenerConfig.child_spec(
      config.read,
      {ServiceRadarNVR.Playback, config},
      __MODULE__,
      config.playback_read_slots + 8
    )
  end
end
