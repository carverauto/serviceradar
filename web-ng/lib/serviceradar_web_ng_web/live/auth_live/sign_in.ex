defmodule ServiceRadarWebNGWeb.AuthLive.SignIn do
  @moduledoc """
  LiveView wrapper for AshAuthentication.Phoenix sign-in components.

  Renders the authentication UI for password sign-in.
  """
  use ServiceRadarWebNGWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md p-6">
        <div class="text-center mb-8 space-y-3">
          <div class="flex items-center justify-center gap-3">
            <img
              src={~p"/images/logo.svg"}
              alt="ServiceRadar"
              class="h-10 w-auto"
              width="40"
              height="40"
            />
            <span class="text-3xl font-semibold tracking-tight text-base-content">
              ServiceRadar
            </span>
          </div>
          <h1 class="text-xl font-semibold">Sign in to your account</h1>
        </div>

        <.live_component
          module={AshAuthentication.Phoenix.Components.SignIn}
          id="sign-in-component"
          otp_app={:serviceradar_web_ng}
          live_action={@live_action}
          path={~p"/users/log-in"}
          auth_routes_prefix="/auth"
          overrides={[
            ServiceRadarWebNGWeb.AuthOverrides,
            AshAuthentication.Phoenix.Overrides.Default
          ]}
        />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end
