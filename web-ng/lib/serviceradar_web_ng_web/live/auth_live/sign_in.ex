defmodule ServiceRadarWebNGWeb.AuthLive.SignIn do
  @moduledoc """
  LiveView for user sign-in.

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

        <.form
          for={@form}
          action={~p"/auth/sign-in"}
          method="post"
          class="space-y-4"
        >
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
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    form = to_form(%{"email" => "", "password" => ""}, as: :user)
    {:ok, assign(socket, form: form)}
  end
end
