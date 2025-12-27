defmodule ServiceRadarWebNGWeb.AuthLive.MagicLinkSignIn do
  @moduledoc """
  LiveView confirmation page for magic link sign-in.
  """
  use ServiceRadarWebNGWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    {:ok, assign(socket, token: nil, csrf_token: csrf_token)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    token = params["token"] || params["magic_link"]

    {:noreply, assign(socket, token: token)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md">
        <div class="rounded-2xl border border-slate-200/70 bg-white p-6 shadow-sm">
          <div class="text-center">
            <p class="text-xs uppercase tracking-[0.25em] text-slate-400">
              ServiceRadar
            </p>
            <h1 class="mt-3 text-2xl font-semibold text-slate-900">Confirm sign-in</h1>
            <p class="mt-2 text-sm text-slate-500">
              Finish signing in to your workspace.
            </p>
          </div>

          <%= if @token do %>
            <form
              id="magic-link-confirm-form"
              action={~p"/auth/user/magic_link"}
              method="post"
              class="mt-6 space-y-4"
            >
              <input type="hidden" name="_csrf_token" value={@csrf_token} />
              <input type="hidden" name="token" value={@token} />

              <button
                type="submit"
                class="w-full rounded-full bg-slate-900 px-4 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-slate-800 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-slate-900"
              >
                Sign in
              </button>

              <p class="text-center text-xs text-slate-400">
                If this was not you, you can close this tab.
              </p>
            </form>
          <% else %>
            <div class="mt-6 rounded-xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">
              Missing or invalid magic link token.
            </div>
            <div class="mt-4 text-center">
              <.link
                navigate={~p"/users/log-in"}
                class="text-sm font-semibold text-slate-900 underline decoration-slate-300 underline-offset-4 hover:text-slate-700"
              >
                Back to sign in
              </.link>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
