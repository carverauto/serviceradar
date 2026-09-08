defmodule ServiceRadarAgentGateway.CertIssuanceAudit do
  @moduledoc """
  Writes gateway-issued agent certificate mint events to the shared audit stream.

  The event intentionally contains only issuance metadata. It must never include
  private keys, certificate PEM bodies, bundles, CA key paths, or download tokens.
  """

  alias ServiceRadar.Events.AuditWriter

  require Logger

  @spec write(keyword() | map()) :: :ok
  def write(event) when is_map(event) do
    event
    |> Map.to_list()
    |> write()
  end

  def write(event) when is_list(event) do
    event
    |> Keyword.take([:action, :resource_type, :resource_id, :resource_name, :actor, :details, :severity, :message])
    |> AuditWriter.write_async()

    :ok
  rescue
    error ->
      Logger.warning("[CertIssuanceAudit] Failed to enqueue certificate issuance audit: #{inspect(error)}")
      :ok
  end
end
