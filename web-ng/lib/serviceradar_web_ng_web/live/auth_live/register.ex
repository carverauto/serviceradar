defmodule ServiceRadarWebNGWeb.AuthLive.Register do
  @moduledoc """
  Registration page.

  In the dedicated deployment architecture, user registration is handled
  by the administrator. New user registration is not available through the web UI.
  Users are created by the control plane when a new deployment is provisioned.
  """
  use ServiceRadarWebNGWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    # In single-deployment mode, registration is not available via web UI
    {:ok, assign(socket, error: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-md p-6">
      <div class="text-center mb-6">
        <h1 class="text-2xl font-bold">Registration Not Available</h1>
        <p class="text-base-content/70 mt-4">
          User registration is managed by your organization's administrator.
        </p>
        <p class="text-base-content/70 mt-2">
          If you already have an account:
          <.link navigate={~p"/users/log-in"} class="link link-primary">
            Sign in
          </.link>
        </p>
      </div>

      <div class="alert alert-info">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          fill="none"
          viewBox="0 0 24 24"
          class="stroke-current shrink-0 w-6 h-6"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
          >
          </path>
        </svg>
        <span>Contact your administrator to request an account.</span>
      </div>
    </div>
    """
  end
end
