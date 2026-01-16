defmodule ServiceRadar.Edge.PubSub do
  @moduledoc """
  PubSub broadcaster for edge collector and NATS credential events.

  Broadcasts to `ServiceRadar.PubSub` which should be started by the host
  application (e.g., web-ng). If the PubSub is not running, broadcasts
  are silently ignored.

  DB connection's search_path determines the schema - each tenant gets their own deployment.

  ## Topics

  - `collectors` - All collector updates
  - `collectors:package:<package_id>` - Specific package updates
  - `nats:credentials` - NATS credential updates

  ## Events

  - `{:package_created, package}`
  - `{:package_updated, package, old_status, new_status}`
  - `{:package_revoked, package}`
  - `{:credential_created, credential}`
  - `{:credential_revoked, credential}`
  """

  @pubsub ServiceRadar.PubSub

  # Topic helpers

  def collectors_topic, do: "collectors"
  def package_topic(package_id), do: "collectors:package:#{package_id}"
  def nats_credentials_topic, do: "nats:credentials"

  # Package broadcasts

  @doc """
  Broadcast a collector package creation event.
  """
  def broadcast_package_created(package) do
    event = {:package_created, package}
    safe_broadcast(collectors_topic(), event)
    safe_broadcast(package_topic(package.id), event)
  end

  @doc """
  Broadcast a collector package status change.
  """
  def broadcast_package_status_changed(package, old_status, new_status) do
    event = {:package_updated, package, old_status, new_status}
    safe_broadcast(collectors_topic(), event)
    safe_broadcast(package_topic(package.id), event)

    if new_status == :revoked do
      revoke_event = {:package_revoked, package}
      safe_broadcast(collectors_topic(), revoke_event)
    end
  end

  # Credential broadcasts

  @doc """
  Broadcast a NATS credential creation event.
  """
  def broadcast_credential_created(credential) do
    event = {:credential_created, credential}
    safe_broadcast(nats_credentials_topic(), event)
  end

  @doc """
  Broadcast a NATS credential revocation event.
  """
  def broadcast_credential_revoked(credential) do
    event = {:credential_revoked, credential}
    safe_broadcast(nats_credentials_topic(), event)
  end

  # Safe broadcast - silently ignores if PubSub is not running
  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
