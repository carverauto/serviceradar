defmodule ServiceRadarWebNGWeb.Admin.NatsLive.Show do
  @moduledoc """
  LiveView for NATS account details.

  In single-tenant-per-deployment architecture, NATS accounts are provisioned
  and managed by the control plane. This page redirects to the NATS admin index.
  """
  use ServiceRadarWebNGWeb, :live_view

  @impl true
  def mount(%{"id" => _id}, _session, socket) do
    # In single-tenant mode, redirect to the NATS admin index
    # Individual tenant NATS details are managed by the control plane
    socket =
      socket
      |> put_flash(:info, "NATS accounts are managed by the control plane")
      |> push_navigate(to: ~p"/admin/nats")

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    # This render is never actually called since mount redirects,
    # but LiveView requires a render callback
    ~H"""
    <div>Redirecting...</div>
    """
  end
end
