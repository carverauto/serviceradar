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

  require Logger

  alias ServiceRadarWebNGWeb.Auth.RateLimiter

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
          <h1 class="text-xl font-semibold">Administrator Login</h1>
          <p class="text-sm text-base-content/60">
            Local authentication for administrators
          </p>
        </div>

        <div class="alert alert-warning mb-6">
          <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
          </svg>
          <span class="text-sm">
            This login is for administrators only. Regular users should authenticate through
            the organization's identity provider.
          </span>
        </div>

        <%= if @rate_limited do %>
          <div class="alert alert-error mb-6">
            <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            <span>Too many login attempts. Please try again in <%= @retry_after %> seconds.</span>
          </div>
        <% else %>
          <.form for={@form} action={~p"/auth/local/sign-in"} method="post" class="space-y-4">
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
                placeholder="admin@example.com"
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
          </.form>
        <% end %>

        <div class="mt-6 text-center">
          <a href={~p"/users/log-in"} class="link link-secondary text-sm">
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
    case RateLimiter.check_rate_limit("local_auth", ip, limit: 5, window_seconds: 60) do
      :ok -> {false, 0}
      {:error, retry_after} -> {true, retry_after}
    end
  end
end
