defmodule ServiceRadarWebNG.Collectors.PubSub do
  @moduledoc """
  PubSub helpers for collector package and NATS credential updates.

  Provides topic/subscription management for real-time updates in LiveViews.

  This module uses instance-scoped topics since each tenant instance serves
  a single tenant - there's no need for tenant identifiers in topic names.

  ## Topics

  - `collectors:instance` - All collector updates for this instance
  - `collectors:package:<package_id>` - Specific package updates
  - `nats:instance` - NATS credential updates for this instance

  ## Events

  - `{:package_created, package}`
  - `{:package_updated, package, old_status, new_status}`
  - `{:package_revoked, package}`
  - `{:credential_created, credential}`
  - `{:credential_revoked, credential}`
  - `{:nats_status_updated, status}`
  """

  # Use ServiceRadar.PubSub - same as serviceradar_core broadcasts to
  @pubsub ServiceRadar.PubSub

  # Topic helpers

  def collectors_topic, do: "collectors:instance"
  def package_topic(package_id), do: "collectors:package:#{package_id}"
  def nats_topic, do: "nats:instance"

  # Subscribe helpers

  @doc """
  Subscribe to collector updates for this instance.
  """
  def subscribe_collectors do
    Phoenix.PubSub.subscribe(@pubsub, collectors_topic())
  end

  @doc """
  Subscribe to updates for a specific package.
  """
  def subscribe_package(package_id) do
    Phoenix.PubSub.subscribe(@pubsub, package_topic(package_id))
  end

  @doc """
  Subscribe to NATS updates for this instance.
  """
  def subscribe_nats do
    Phoenix.PubSub.subscribe(@pubsub, nats_topic())
  end

  # Broadcast helpers

  @doc """
  Broadcast a collector package creation event.
  """
  def broadcast_package_created(package) do
    event = {:package_created, package}
    broadcast_to_collectors(event)
    broadcast_to_package(package.id, event)
  end

  @doc """
  Broadcast a collector package status change.
  """
  def broadcast_package_status_changed(package, old_status, new_status) do
    event = {:package_updated, package, old_status, new_status}
    broadcast_to_collectors(event)
    broadcast_to_package(package.id, event)

    # If revoked, send specific event
    if new_status == :revoked do
      revoke_event = {:package_revoked, package}
      broadcast_to_collectors(revoke_event)
    end
  end

  @doc """
  Broadcast a NATS credential creation event.
  """
  def broadcast_credential_created(credential) do
    event = {:credential_created, credential}
    broadcast_to_nats(event)
  end

  @doc """
  Broadcast a NATS credential revocation event.
  """
  def broadcast_credential_revoked(credential) do
    event = {:credential_revoked, credential}
    broadcast_to_nats(event)
  end

  @doc """
  Broadcast a NATS account status change.
  """
  def broadcast_nats_status(status) do
    event = {:nats_status_updated, status}
    broadcast_to_nats(event)
  end

  # Private broadcast functions

  defp broadcast_to_collectors(event) do
    Phoenix.PubSub.broadcast(@pubsub, collectors_topic(), event)
  end

  defp broadcast_to_package(package_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, package_topic(package_id), event)
  end

  defp broadcast_to_nats(event) do
    Phoenix.PubSub.broadcast(@pubsub, nats_topic(), event)
  end
end
