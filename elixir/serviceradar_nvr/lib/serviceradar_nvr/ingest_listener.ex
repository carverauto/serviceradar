defmodule ServiceRadarNVR.IngestListener do
  @moduledoc """
  Opt-in private TLS input for trusted recording coordinators.

  The installed client certificate pin and separate token identify ServiceRadar
  workloads, not cameras. The coordinator must hold recording authority and
  exclusive source ownership before submitting media. This listener does not
  enroll recorders, initialize storage or grant catalog availability.
  """

  alias ServiceRadarNVR.ListenerConfig

  def load(env) do
    ListenerConfig.load(
      env,
      "SERVICERADAR_NVR_INGEST_CONFIG_FILE",
      "SERVICERADAR_NVR_INGEST_TOKEN_FILE",
      :invalid_nvr_ingest_config
    )
  end

  def child_spec(config), do: ListenerConfig.child_spec(config.ingest, {ServiceRadarNVR.Ingest, config}, __MODULE__, 8)
end
