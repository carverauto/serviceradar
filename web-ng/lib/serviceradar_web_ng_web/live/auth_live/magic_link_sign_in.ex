defmodule ServiceRadarWebNGWeb.AuthLive.MagicLinkSignIn do
  @moduledoc """
  LiveView confirmation page for magic link sign-in.
  """
  use ServiceRadarWebNGWeb, :live_view

  @impl true
  def mount(params, _session, socket) do
    token = params["token"] || params["magic_link"]
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    {:ok, assign(socket, token: token, csrf_token: csrf_token)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-md p-6">
      <div class="text-center mb-6">
        <h1 class="text-2xl font-bold">Confirm sign-in</h1>
        <p class="text-base-content/70 mt-2">
          Click the button below to finish signing in.
        </p>
      </div>

      <%= if @token do %>
        <form method="post" action={~p"/auth/user/magic_link"} class="space-y-4">
          <input type="hidden" name="_csrf_token" value={@csrf_token} />
          <input type="hidden" name="token" value={@token} />
          <button type="submit" class="btn btn-primary w-full">Sign in</button>
        </form>
      <% else %>
        <div class="alert alert-error">
          <span>Missing or invalid magic link token.</span>
        </div>
        <div class="mt-4 text-center">
          <.link navigate={~p"/users/log-in"} class="link link-primary">
            Back to sign in
          </.link>
        </div>
      <% end %>
    </div>
    """
  end
end
