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
  alias ServiceRadarWebNGWeb.Auth.LoginPolicy

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <div class="mx-auto max-w-md p-6">
        <div class="mb-8 space-y-3 text-center">
          <div class="flex items-center justify-center gap-3">
            <span class="sr-public-brand-mark">
              <img
                src={~p"/images/logo-animated.svg"}
                alt=""
                aria-hidden="true"
                width="28"
                height="28"
              />
            </span>
            <span class="text-3xl font-semibold tracking-tight text-sr-ink">
              ServiceRadar
            </span>
          </div>
          <h1 class="text-xl font-semibold text-sr-ink">Sign in to your account</h1>
        </div>

        <%= case @auth_mode do %>
          <% :passive_proxy -> %>
            <.proxy_mode_message force_local_login={@force_local_login} form={@form} />
          <% :active_sso -> %>
            <.sso_login_section
              disable_sso={@disable_sso}
              force_local_login={@force_local_login}
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
    <div class="flex gap-3 rounded-sr-surface border border-sky-500/30 bg-sky-500/10 p-4 text-sr-ink">
      <.icon name="hero-information-circle" class="size-6 shrink-0 text-sky-600 dark:text-sky-300" />
      <div>
        <h3 class="font-semibold">Gateway Authentication Required</h3>
        <p class="mt-1 text-sm text-sr-muted">
          This application requires authentication through your organization's API gateway.
          Please ensure you're accessing this through the proper gateway URL.
        </p>
      </div>
    </div>

    <%= if @force_local_login do %>
      <div class="mt-6">
        <.password_form form={@form} />
      </div>
    <% end %>

    <div class="mt-6 text-center">
      <a
        href={~p"/auth/local"}
        class="text-sm font-semibold text-sr-muted outline-none hover:text-sr-brand focus-visible:ring-2 focus-visible:ring-sr-focus"
      >
        Administrator Login
      </a>
    </div>
    """
  end

  defp sso_login_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <%= unless @disable_sso do %>
        <a
          href={~p"/auth/oidc"}
          class="inline-flex w-full min-h-12 items-center justify-center gap-2 rounded-sr-control border border-transparent bg-sr-brand px-4 text-base font-semibold text-sr-on-brand shadow-sr-button outline-none transition-[transform,background-color] duration-200 ease-sr-out hover:bg-sr-brand-strong focus-visible:ring-2 focus-visible:ring-sr-focus active:translate-y-px"
        >
          <.icon name="hero-key" class="size-5" /> Sign in with Enterprise SSO
        </a>
      <% end %>

      <%!--
        Acceptance is enforced server-side by LoginPolicy. Regular accounts are
        SSO-only; only accounts with local login enabled (or the env break-glass) are
        accepted. When break-glass is active we render the local form inline.
      --%>
      <%= if @force_local_login do %>
        <div class="flex items-center gap-3 text-xs font-semibold uppercase tracking-[0.16em] text-sr-muted">
          <span class="h-px flex-1 bg-sr-line"></span> Or <span class="h-px flex-1 bg-sr-line"></span>
        </div>
        <.password_form form={@form} />
      <% else %>
        <div class="text-center">
          <a
            href={~p"/auth/local"}
            class="text-sm font-semibold text-sr-muted outline-none hover:text-sr-brand focus-visible:ring-2 focus-visible:ring-sr-focus"
          >
            Sign in with a local password
          </a>
        </div>
      <% end %>
    </div>
    """
  end

  defp password_form(assigns) do
    ~H"""
    <.form
      for={@form}
      action={~p"/auth/sign-in"}
      method="post"
      class="space-y-4"
      data-disable-on-submit="true"
    >
      <div class="grid gap-1.5">
        <label for="user_email" class="text-sm font-medium text-sr-ink">Email</label>
        <input
          type="email"
          id="user_email"
          name="user[email]"
          value={@form[:email].value}
          class="w-full min-h-11 rounded-sr-control border border-sr-line bg-sr-control px-3.5 text-sm text-sr-ink shadow-sr-control outline-none transition-[border-color,box-shadow] duration-200 ease-sr-out placeholder:text-sr-muted focus-visible:border-sr-line-hover focus-visible:ring-2 focus-visible:ring-sr-focus"
          placeholder="you@example.com"
          required
          autofocus
        />
      </div>

      <div class="grid gap-1.5">
        <label for="user_password" class="text-sm font-medium text-sr-ink">Password</label>
        <input
          type="password"
          id="user_password"
          name="user[password]"
          class="w-full min-h-11 rounded-sr-control border border-sr-line bg-sr-control px-3.5 text-sm text-sr-ink shadow-sr-control outline-none transition-[border-color,box-shadow] duration-200 ease-sr-out placeholder:text-sr-muted focus-visible:border-sr-line-hover focus-visible:ring-2 focus-visible:ring-sr-focus"
          placeholder="Enter your password"
          required
        />
      </div>

      <button
        type="submit"
        class="inline-flex w-full min-h-11 items-center justify-center rounded-sr-control border border-transparent bg-sr-brand px-3.5 text-sm font-semibold text-sr-on-brand shadow-sr-button outline-none transition-[transform,background-color] duration-200 ease-sr-out hover:bg-sr-brand-strong focus-visible:ring-2 focus-visible:ring-sr-focus active:translate-y-px"
        data-submit-label="Signing in..."
      >
        Sign in
      </button>

      <div class="text-center text-sm">
        <a
          href={~p"/auth/password-reset"}
          class="font-semibold text-sr-brand outline-none hover:text-sr-brand-strong focus-visible:ring-2 focus-visible:ring-sr-focus"
        >
          Forgot your password?
        </a>
      </div>
    </.form>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    form = to_form(%{"email" => "", "password" => ""}, as: :user)

    # Get auth settings from cache. The form is presentation only; acceptance is
    # enforced server-side by ServiceRadarWebNGWeb.Auth.LoginPolicy.
    auth_mode = get_auth_mode()

    {:ok,
     assign(socket,
       form: form,
       auth_mode: auth_mode,
       force_local_login: LoginPolicy.force_local_login?(),
       disable_sso: LoginPolicy.disable_sso?()
     )}
  end

  defp get_auth_mode do
    case ConfigCache.get_settings() do
      {:ok, %{is_enabled: true, mode: mode}} -> mode
      {:ok, _settings} -> :password_only
      # Presentation default; the server-side policy still governs acceptance.
      {:error, _} -> :password_only
    end
  end
end
