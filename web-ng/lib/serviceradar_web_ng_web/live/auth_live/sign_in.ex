defmodule ServiceRadarWebNGWeb.AuthLive.SignIn do
  @moduledoc """
  LiveView wrapper for AshAuthentication.Phoenix sign-in components.

  Renders the appropriate authentication UI based on the live_action:
  - :sign_in - Shows sign-in form with password and magic link options
  - :register - Shows registration form
  """
  use ServiceRadarWebNGWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-md p-6">
      <div class="text-center mb-6">
        <h1 class="text-2xl font-bold">
          <%= if @live_action == :register do %>
            Create an account
          <% else %>
            Sign in to your account
          <% end %>
        </h1>
        <p class="text-base-content/70 mt-2">
          <%= if @live_action == :register do %>
            Already have an account?
            <.link navigate={~p"/users/log-in"} class="link link-primary">
              Sign in
            </.link>
          <% else %>
            Don't have an account?
            <.link navigate={~p"/users/register"} class="link link-primary">
              Sign up
            </.link>
          <% end %>
        </p>
      </div>

      <.live_component
        module={AshAuthentication.Phoenix.Components.SignIn}
        id="sign-in-component"
        otp_app={:serviceradar_web_ng}
        live_action={@live_action}
        path={~p"/users/log-in"}
        register_path={~p"/users/register"}
        overrides={[ServiceRadarWebNGWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]}
      />
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end
