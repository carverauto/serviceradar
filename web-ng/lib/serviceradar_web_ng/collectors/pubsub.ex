defmodule ServiceRadarWebNG.Collectors.PubSub do
  @moduledoc """
  PubSub helpers for collector package and NATS credential updates.

  Provides topic/subscription management for real-time updates in LiveViews.

  ## Topics

  - `collectors:tenant:<tenant_id>` - All collector updates for a tenant
  - `collectors:package:<package_id>` - Specific package updates
  - `nats:tenant:<tenant_id>` - NATS account/credential updates for a tenant
  - `nats:admin` - Admin-level NATS updates (operator, all tenants)

  ## Events

  - `{:package_created, package}`
  - `{:package_updated, package, old_status, new_status}`
  - `{:package_revoked, package}`
  - `{:credential_created, credential}`
  - `{:credential_revoked, credential}`
  - `{:tenant_nats_updated, tenant_id, status}`
  """

  # Use ServiceRadar.PubSub - same as serviceradar_core broadcasts to
  @pubsub ServiceRadar.PubSub

  # Topic helpers

  def tenant_collectors_topic(tenant_id), do: "collectors:tenant:#{tenant_id}"
  def package_topic(package_id), do: "collectors:package:#{package_id}"
  def tenant_nats_topic(tenant_id), do: "nats:tenant:#{tenant_id}"
  def admin_nats_topic, do: "nats:admin"

  # Subscribe helpers

  def subscribe_tenant_collectors(tenant_id) do
    Phoenix.PubSub.subscribe(@pubsub, tenant_collectors_topic(tenant_id))
  end

  def subscribe_package(package_id) do
    Phoenix.PubSub.subscribe(@pubsub, package_topic(package_id))
  end

  def subscribe_tenant_nats(tenant_id) do
    Phoenix.PubSub.subscribe(@pubsub, tenant_nats_topic(tenant_id))
  end

  def subscribe_admin_nats do
    Phoenix.PubSub.subscribe(@pubsub, admin_nats_topic())
  end

  # Broadcast helpers

  @doc """
  Broadcast a collector package creation event.
  """
  def broadcast_package_created(package) do
    event = {:package_created, package}
    broadcast_to_tenant(package.tenant_id, event)
    broadcast_to_package(package.id, event)
  end

  @doc """
  Broadcast a collector package status change.
  """
  def broadcast_package_status_changed(package, old_status, new_status) do
    event = {:package_updated, package, old_status, new_status}
    broadcast_to_tenant(package.tenant_id, event)
    broadcast_to_package(package.id, event)

    # If revoked, send specific event
    if new_status == :revoked do
      revoke_event = {:package_revoked, package}
      broadcast_to_tenant(package.tenant_id, revoke_event)
    end
  end

  @doc """
  Broadcast a NATS credential creation event.
  """
  def broadcast_credential_created(credential) do
    event = {:credential_created, credential}
    broadcast_to_tenant_nats(credential.tenant_id, event)
  end

  @doc """
  Broadcast a NATS credential revocation event.
  """
  def broadcast_credential_revoked(credential) do
    event = {:credential_revoked, credential}
    broadcast_to_tenant_nats(credential.tenant_id, event)
  end

  @doc """
  Broadcast a tenant NATS account status change.
  """
  def broadcast_tenant_nats_status(tenant_id, status) do
    event = {:tenant_nats_updated, tenant_id, status}
    broadcast_to_tenant_nats(tenant_id, event)
    broadcast_to_admin_nats(event)
  end

  @doc """
  Broadcast an operator status change (admin only).
  """
  def broadcast_operator_status(operator) do
    event = {:operator_updated, operator}
    broadcast_to_admin_nats(event)
  end

  # Private broadcast functions

  defp broadcast_to_tenant(tenant_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, tenant_collectors_topic(tenant_id), event)
  end

  defp broadcast_to_package(package_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, package_topic(package_id), event)
  end

  defp broadcast_to_tenant_nats(tenant_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, tenant_nats_topic(tenant_id), event)
  end

  defp broadcast_to_admin_nats(event) do
    Phoenix.PubSub.broadcast(@pubsub, admin_nats_topic(), event)
  end
end
