defmodule ServiceRadar.Identity.TenantLifecyclePublisher do
  @moduledoc """
  Publishes tenant lifecycle events to NATS for workload provisioning.

  Subjects:
  - `serviceradar.tenants.lifecycle.created`
  - `serviceradar.tenants.lifecycle.updated`
  - `serviceradar.tenants.lifecycle.deleted`

  Payload schema:
  ```json
  {
    "event_type": "tenant.created",
    "tenant_id": "uuid",
    "tenant_slug": "platform",
    "status": "active",
    "plan": "free",
    "is_platform_tenant": false,
    "nats_account_status": "pending",
    "workloads": ["agent_gateway", "zen_consumer"],
    "timestamp": "2024-01-01T00:00:00Z"
  }
  ```
  """

  require Logger

  alias ServiceRadar.NATS.Connection

  @subject_prefix "serviceradar.tenants.lifecycle"
  @stream_name "TENANT_PROVISIONING"

  @default_workloads ["agent_gateway", "zen_consumer"]

  @spec publish_created(struct(), keyword()) :: :ok | {:error, term()}
  def publish_created(tenant, opts \\ []) do
    publish_event("created", tenant, opts)
  end

  @spec publish_updated(struct(), keyword()) :: :ok | {:error, term()}
  def publish_updated(tenant, opts \\ []) do
    publish_event("updated", tenant, opts)
  end

  @spec publish_deleted(struct(), keyword()) :: :ok | {:error, term()}
  def publish_deleted(tenant, opts \\ []) do
    publish_event("deleted", tenant, opts)
  end

  @spec stream_name() :: String.t()
  def stream_name, do: @stream_name

  @spec subject_pattern() :: String.t()
  def subject_pattern, do: "#{@subject_prefix}.>"

  @spec subject_for_action(String.t()) :: String.t()
  def subject_for_action(action) when is_binary(action) do
    "#{@subject_prefix}.#{action}"
  end

  defp publish_event(action, tenant, opts) do
    subject = subject_for_action(action)
    payload = build_payload(action, tenant, opts)

    case Jason.encode(payload) do
      {:ok, json} ->
        case Connection.publish(subject, json) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Tenant lifecycle publish failed",
              subject: subject,
              reason: inspect(reason)
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Failed to encode tenant lifecycle payload", reason: inspect(reason))
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("Tenant lifecycle publish raised", error: Exception.message(e))
      {:error, e}
  end

  defp build_payload(action, tenant, opts) do
    %{
      event_type: "tenant.#{action}",
      tenant_id: tenant.id,
      tenant_slug: tenant.slug |> to_string(),
      status: tenant.status |> to_string(),
      plan: tenant.plan |> to_string(),
      is_platform_tenant: tenant.is_platform_tenant || false,
      nats_account_status: normalize_nats_status(tenant.nats_account_status),
      workloads: Keyword.get(opts, :workloads, @default_workloads),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp normalize_nats_status(nil), do: nil
  defp normalize_nats_status(status) when is_atom(status), do: to_string(status)
  defp normalize_nats_status(status), do: status
end
