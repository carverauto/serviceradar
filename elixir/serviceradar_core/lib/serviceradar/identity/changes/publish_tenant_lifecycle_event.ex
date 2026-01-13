defmodule ServiceRadar.Identity.Changes.PublishTenantLifecycleEvent do
  @moduledoc """
  Publishes tenant lifecycle events after transaction completion.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Identity.TenantLifecyclePublisher

  require Logger

  @impl true
  def change(changeset, opts, _context) do
    event = Keyword.get(opts, :event, :updated)
    workloads = Keyword.get(opts, :workloads)
    publish_opts = workloads_opts(workloads)

    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, tenant} ->
          publish_event(event, tenant, publish_opts)
          {:ok, tenant}

        {:error, _reason} ->
          result
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp publish_event(:created, tenant, publish_opts) do
    TenantLifecyclePublisher.publish_created(tenant, publish_opts)
    |> handle_publish_result(:created, tenant.id)
  end

  defp publish_event(:updated, tenant, publish_opts) do
    TenantLifecyclePublisher.publish_updated(tenant, publish_opts)
    |> handle_publish_result(:updated, tenant.id)
  end

  defp publish_event(:deleted, tenant, publish_opts) do
    TenantLifecyclePublisher.publish_deleted(tenant, publish_opts)
    |> handle_publish_result(:deleted, tenant.id)
  end

  defp publish_event(event, tenant, publish_opts) do
    Logger.warning("Unknown tenant lifecycle event", event: event, tenant_id: tenant.id)
    publish_event(:updated, tenant, publish_opts)
  end

  defp handle_publish_result(:ok, _event, _tenant_id), do: :ok

  defp handle_publish_result({:error, reason}, event, tenant_id) do
    Logger.warning("Tenant lifecycle publish failed",
      event: event,
      tenant_id: tenant_id,
      reason: inspect(reason)
    )

    :ok
  end

  defp workloads_opts(nil), do: []
  defp workloads_opts([]), do: []
  defp workloads_opts(workloads), do: [workloads: workloads]
end
