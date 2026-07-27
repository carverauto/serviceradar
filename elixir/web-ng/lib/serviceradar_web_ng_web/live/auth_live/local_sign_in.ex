defmodule ServiceRadarWebNGWeb.AuthLive.LocalSignIn do
  @moduledoc """
  LiveView for local administrator sign-in.

  This is the "backdoor" login page for administrators when the system is
  configured for passive proxy (gateway) authentication. It allows local
  admins to sign in with password credentials even when SSO is the primary
  authentication method.

  ## Security Considerations

  - Rate limited to prevent brute force attacks
  - Only accessible at `/auth/local`
  - Should be protected by network-level controls in production
  - Logs all access attempts for audit purposes
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Security.RateLimiter

  require Logger

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
          <h1 class="text-xl font-semibold text-sr-ink">Administrator Login</h1>
          <p class="text-sm text-sr-muted">
            Local authentication for administrators
          </p>
        </div>

        <div class="mb-6 flex gap-3 rounded-sr-surface border border-amber-500/30 bg-amber-500/10 p-4 text-sr-ink">
          <.icon
            name="hero-exclamation-triangle"
            class="size-6 shrink-0 text-amber-600 dark:text-amber-300"
          />
          <span class="text-sm text-sr-muted">
            This login is for administrators only. Regular users should authenticate through
            the organization's identity provider.
          </span>
        </div>

        <%= if @rate_limited do %>
          <div class="mb-6 flex gap-3 rounded-sr-surface border border-rose-500/30 bg-rose-500/10 p-4 text-sr-ink">
            <.icon name="hero-x-circle" class="size-6 shrink-0 text-rose-600 dark:text-rose-300" />
            <span class="text-sm">
              Too many login attempts. Please try again in {@retry_after} seconds.
            </span>
          </div>
        <% else %>
          <.form
            for={@form}
            action={~p"/auth/local/sign-in"}
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
                placeholder="admin@example.com"
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
          </.form>
        <% end %>

        <div class="mt-6 text-center">
          <a
            href={~p"/users/log-in"}
            class="text-sm font-semibold text-sr-muted outline-none hover:text-sr-brand focus-visible:ring-2 focus-visible:ring-sr-focus"
          >
            ← Back to main login
          </a>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    # Get client IP for rate limiting
    client_ip = get_client_ip(socket)

    # Log access attempt
    Logger.info("Local admin login page accessed from IP: #{client_ip}")

    # Check rate limit
    {rate_limited, retry_after} = check_rate_limit(client_ip)

    form = to_form(%{"email" => "", "password" => ""}, as: :user)

    {:ok,
     assign(socket,
       form: form,
       rate_limited: rate_limited,
       retry_after: retry_after,
       client_ip: client_ip
     )}
  end

  defp get_client_ip(socket) do
    # Try to get IP from socket assigns (set by endpoint)
    case socket.assigns do
      %{client_ip: ip} when is_binary(ip) -> ip
      _ -> "unknown"
    end
  end

  defp check_rate_limit(ip) do
    case RateLimiter.check(:auth_local, ip, limit: 5, window_seconds: 60) do
      :ok -> {false, 0}
      {:error, retry_after} -> {true, retry_after}
    end
  end
end
