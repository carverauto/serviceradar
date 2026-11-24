defmodule ServiceRadarNVR.AnalysisReadListener do
  @moduledoc """
  Opt-in private TLS listener that serves verified sealed local blocks to
  `serviceradar-media-worker` for immediate visual keyframe indexing before
  S3 archive verification completes.

  It is isolated from both the ingest listener (`nvr.ingest.port`) and the
  web-ng playback listener (`nvr.read.port`): its own port, client certificate
  pin, analysis-read bearer token, and dedicated `ServiceRadarNVR.AnalysisReadTasks`
  pool so background visual indexing cannot starve interactive playback or
  ingest/archive operations. `ServiceRadarNVR.Config` refuses any installation
  that shares a port, pin, or token with ingest or playback read.
  """

  alias ServiceRadarNVR.ListenerConfig

  def load(env) do
    ListenerConfig.load(
      env,
      "SERVICERADAR_NVR_ANALYSIS_READ_CONFIG_FILE",
      "SERVICERADAR_NVR_ANALYSIS_READ_TOKEN_FILE",
      :invalid_nvr_analysis_read_config
    )
  end

  # Connections beyond the analysis read slots are answered 503 by the pool,
  # not left waiting in the acceptor queue.
  def child_spec(config) do
    ListenerConfig.child_spec(
      config.analysis_read,
      {ServiceRadarNVR.Playback, {:analysis, config}},
      __MODULE__,
      config.analysis_read_slots + 8
    )
  end
end
