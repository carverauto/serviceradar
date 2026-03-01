defmodule ServiceRadarWebNG.Edge.PubSub do
  @moduledoc """
  PubSub helpers for edge onboarding package updates.

  Topics are instance-scoped since each deployment is single-tenant.
  """

  @pubsub ServiceRadar.PubSub

  def packages_topic, do: "edge-packages:instance"
  def package_topic(package_id), do: "edge-packages:package:#{package_id}"

  def subscribe_packages do
    Phoenix.PubSub.subscribe(@pubsub, packages_topic())
  end

  def subscribe_package(package_id) do
    Phoenix.PubSub.subscribe(@pubsub, package_topic(package_id))
  end

  def broadcast_package_created(package) do
    broadcast(packages_topic(), {:edge_package_created, package})
    broadcast(package_topic(package.id), {:edge_package_created, package})
  end

  def broadcast_package_updated(package) do
    broadcast(packages_topic(), {:edge_package_updated, package})
    broadcast(package_topic(package.id), {:edge_package_updated, package})
  end

  def broadcast_package_deleted(package) do
    broadcast(packages_topic(), {:edge_package_deleted, package})
    broadcast(package_topic(package.id), {:edge_package_deleted, package})
  end

  defp broadcast(topic, event) do
    Phoenix.PubSub.broadcast(@pubsub, topic, event)
  end
end
