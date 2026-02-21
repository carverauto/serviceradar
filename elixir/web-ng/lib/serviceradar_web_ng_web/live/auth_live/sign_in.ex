defmodule ServiceRadarWebNGWeb.AuthLive.SignIn do
  @moduledoc """
  LiveView for user sign-in.

  Renders the authentication UI based on the configured auth mode:
  - Password Only: Shows only the password form
  - Active SSO: Shows "Enterprise Login" button and optionally password form
  - Passive Proxy: Shows message that gateway authentication is required
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.Auth.ConfigCache

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

        <%= case @auth_mode do %>
          <% :passive_proxy -> %>
            <.proxy_mode_message />
          <% :active_sso -> %>
            <.sso_login_section
              allow_password_fallback={@allow_password_fallback}
              provider_type={@provider_type}
              form={@form}
            />
          <% _ -> %>
            <.password_form form={@form} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp proxy_mode_message(assigns) do
    ~H"""
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
      <div>
        <h3 class="font-bold">Gateway Authentication Required</h3>
        <p class="text-sm">
          This application requires authentication through your organization's API gateway.
          Please ensure you're accessing this through the proper gateway URL.
        </p>
      </div>
    </div>

    <div class="mt-6 text-center">
      <a href={~p"/auth/local"} class="link link-secondary text-sm">
        Administrator Login
      </a>
    </div>
    """
  end

  defp sso_login_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <a href={~p"/auth/oidc"} class="btn btn-primary btn-lg w-full">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          fill="none"
          viewBox="0 0 24 24"
          stroke-width="1.5"
          stroke="currentColor"
          class="w-5 h-5"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M15.75 5.25a3 3 0 013 3m3 0a6 6 0 01-7.029 5.912c-.563-.097-1.159.026-1.563.43L10.5 17.25H8.25v2.25H6v2.25H2.25v-2.818c0-.597.237-1.17.659-1.591l6.499-6.499c.404-.404.527-1 .43-1.563A6 6 0 1121.75 8.25z"
          />
        </svg>
        Sign in with Enterprise SSO
      </a>

      <%= if @allow_password_fallback do %>
        <div class="divider">OR</div>
        <.password_form form={@form} />
      <% end %>
    </div>
    """
  end

  defp password_form(assigns) do
    ~H"""
    <.form for={@form} action={~p"/auth/sign-in"} method="post" class="space-y-4">
      <div class="form-control w-full">
        <label class="label" for="user_email">
          <span class="label-text">Email</span>
        </label>
        <input
          type="email"
          id="user_email"
          name="user[email]"
          value={@form[:email].value}
          class="input input-bordered w-full"
          placeholder="you@example.com"
          required
          autofocus
        />
      </div>

      <div class="form-control w-full">
        <label class="label" for="user_password">
          <span class="label-text">Password</span>
        </label>
        <input
          type="password"
          id="user_password"
          name="user[password]"
          class="input input-bordered w-full"
          placeholder="Enter your password"
          required
        />
      </div>

      <div class="form-control">
        <button type="submit" class="btn btn-primary w-full">
          Sign in
        </button>
      </div>

      <div class="text-center text-sm">
        <a href={~p"/auth/password-reset"} class="link link-primary">
          Forgot your password?
        </a>
      </div>
    </.form>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    form = to_form(%{"email" => "", "password" => ""}, as: :user)

    # Get auth settings from cache
    {auth_mode, allow_password_fallback, provider_type} = get_auth_config()

    {:ok,
     assign(socket,
       form: form,
       auth_mode: auth_mode,
       allow_password_fallback: allow_password_fallback,
       provider_type: provider_type
     )}
  end

  defp get_auth_config do
    case ConfigCache.get_settings() do
      {:ok, settings} ->
        mode =
          if settings.is_enabled do
            settings.mode
          else
            :password_only
          end

        {mode, settings.allow_password_fallback, settings.provider_type}

      {:error, _} ->
        # Default to password only if settings not configured
        {:password_only, true, nil}
    end
  end
end
