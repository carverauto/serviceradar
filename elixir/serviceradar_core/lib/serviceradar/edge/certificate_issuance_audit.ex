defmodule ServiceRadar.Edge.CertificateIssuanceAudit do
  @moduledoc """
  Publishes the audit record of a certificate the agent-gateway minted.

  The gateway CA signs agent, add-on and NATS leaf certificates, but the
  gateway runs neither `ServiceRadar.Repo` (the durable publish outbox) nor a
  NATS identity allowed to publish `logs.internal.>`, so an audit record
  written there is lost. `ServiceRadarAgentGateway.CertIssuer` therefore
  returns the record under `:issuance_audit`, and the node that requested the
  certificate over RPC publishes it here. For agent-initiated renewal, the
  gateway forwards only that record asynchronously to core through its existing
  core RPC discovery. Forwarding failure is logged and counted by
  `ServiceRadar.Telemetry.audit_metrics/0` without failing the renewal.

  The certificate exists once the gateway returns, whatever the caller does
  next. The record is published from its own process, outside any transaction
  the caller holds, so a rollback cannot erase the evidence of a mint.
  """

  alias ServiceRadar.Events.AuditWriter

  require Logger

  @doc """
  Publishes the bundle's issuance audit and returns the bundle without it.

  An older gateway may omit the record during a mixed-version rollout. This
  logs a warning and still returns the certificate; upgrading the gateway is
  required to restore issuance auditing for those requests.
  """
  @spec publish(map()) :: map()
  def publish(bundle) when is_map(bundle) do
    case Map.pop(bundle, :issuance_audit) do
      {audit, bundle} when is_list(audit) ->
        AuditWriter.write_async(audit)
        bundle

      {_missing, bundle} ->
        Logger.warning("Gateway returned a certificate without its issuance audit record",
          cn: Map.get(bundle, :cn)
        )

        bundle
    end
  end
end
