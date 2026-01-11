defmodule ServiceRadarWebNGWeb.AuthLive.Register do
  @moduledoc """
  Registration flow with organization creation.

  New users must create an organization (tenant) during registration.
  This creates:
  - A new tenant
  - A user as the owner
  - An owner membership linking them
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Identity.Tenant

  @impl true
  def mount(_params, _session, socket) do
    form =
      %{
        "organization_name" => "",
        "email" => "",
        "password" => "",
        "password_confirmation" => ""
      }
      |> to_form(as: :registration)

    {:ok, assign(socket, form: form, error: nil, submitting: false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-md p-6">
      <div class="text-center mb-6">
        <h1 class="text-2xl font-bold">Create your account</h1>
        <p class="text-base-content/70 mt-2">
          Already have an account?
          <.link navigate={~p"/users/log-in"} class="link link-primary">
            Sign in
          </.link>
        </p>
      </div>

      <.form for={@form} phx-submit="register" phx-change="validate" class="space-y-4">
        <div :if={@error} class="alert alert-error text-sm">
          <.icon name="hero-exclamation-circle" class="size-5" />
          <span>{@error}</span>
        </div>

        <fieldset class="fieldset bg-base-200 border border-base-300 p-4 rounded-box">
          <legend class="fieldset-legend px-2 text-sm font-medium">Organization</legend>

          <label class="label">
            <span class="label-text">Organization name</span>
          </label>
          <input
            type="text"
            name={@form[:organization_name].name}
            value={@form[:organization_name].value}
            placeholder="Acme Corp"
            class="input input-bordered w-full"
            required
            autocomplete="organization"
          />
          <p class="text-xs text-base-content/60 mt-1">
            This will be your organization's name in ServiceRadar
          </p>
        </fieldset>

        <fieldset class="fieldset bg-base-200 border border-base-300 p-4 rounded-box">
          <legend class="fieldset-legend px-2 text-sm font-medium">Your account</legend>

          <label class="label">
            <span class="label-text">Email address</span>
          </label>
          <input
            type="email"
            name={@form[:email].name}
            value={@form[:email].value}
            placeholder="you@example.com"
            class="input input-bordered w-full"
            required
            autocomplete="email"
          />

          <label class="label mt-3">
            <span class="label-text">Password</span>
          </label>
          <input
            type="password"
            name={@form[:password].name}
            value={@form[:password].value}
            placeholder="••••••••"
            class="input input-bordered w-full"
            required
            autocomplete="new-password"
            minlength="8"
          />

          <label class="label mt-3">
            <span class="label-text">Confirm password</span>
          </label>
          <input
            type="password"
            name={@form[:password_confirmation].name}
            value={@form[:password_confirmation].value}
            placeholder="••••••••"
            class="input input-bordered w-full"
            required
            autocomplete="new-password"
          />
        </fieldset>

        <button
          type="submit"
          class="btn btn-primary w-full"
          disabled={@submitting}
        >
          <span :if={@submitting} class="loading loading-spinner loading-sm"></span>
          <span :if={not @submitting}>Create account</span>
        </button>

        <p class="text-xs text-center text-base-content/60">
          By creating an account, you agree to our terms of service.
        </p>
      </.form>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"registration" => params}, socket) do
    form = to_form(params, as: :registration)
    {:noreply, assign(socket, form: form, error: nil)}
  end

  @impl true
  def handle_event("register", %{"registration" => params}, socket) do
    socket = assign(socket, submitting: true, error: nil)

    org_name = params["organization_name"]
    email = params["email"]
    password = params["password"]
    password_confirmation = params["password_confirmation"]

    # Basic validation
    cond do
      String.length(org_name || "") < 2 ->
        {:noreply, assign(socket, submitting: false, error: "Organization name is too short")}

      String.length(password || "") < 8 ->
        {:noreply,
         assign(socket, submitting: false, error: "Password must be at least 8 characters")}

      password != password_confirmation ->
        {:noreply, assign(socket, submitting: false, error: "Passwords do not match")}

      true ->
        do_register(socket, org_name, email, password, password_confirmation)
    end
  end

  defp do_register(socket, org_name, email, password, password_confirmation) do
    case Tenant
         |> Ash.ActionInput.for_action(:register, %{
           name: org_name,
           owner: %{
             email: email,
             password: password,
             password_confirmation: password_confirmation
           }
         })
         |> Ash.create(authorize?: false) do
      {:ok, _tenant} ->
        # Registration successful - redirect to sign in
        socket =
          socket
          |> put_flash(:info, "Account created successfully! Please sign in.")
          |> redirect(to: ~p"/users/log-in")

        {:noreply, socket}

      {:error, %Ash.Error.Invalid{} = error} ->
        error_message = format_ash_error(error)
        form = to_form(socket.assigns.form.params, as: :registration)
        {:noreply, assign(socket, form: form, submitting: false, error: error_message)}

      {:error, error} ->
        error_message = format_ash_error(error)
        form = to_form(socket.assigns.form.params, as: :registration)
        {:noreply, assign(socket, form: form, submitting: false, error: error_message)}
    end
  end

  defp format_ash_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", &format_single_error/1)
  end

  defp format_ash_error(%Ash.Error.Unknown{errors: errors}) when is_list(errors) do
    Enum.map_join(errors, ", ", &format_single_error/1)
  end

  defp format_ash_error(error), do: inspect(error)

  defp format_single_error(%{message: message, field: field}) when is_binary(message) do
    "#{field}: #{message}"
  end

  defp format_single_error(%{message: message}) when is_binary(message) do
    message
  end

  defp format_single_error(error), do: inspect(error)
end
