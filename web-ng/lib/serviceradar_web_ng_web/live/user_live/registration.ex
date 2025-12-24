defmodule ServiceRadarWebNGWeb.UserLive.Registration do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Accounts
  alias ServiceRadarWebNG.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Register for an account
            <:subtitle>
              Already registered?
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            required
            phx-mounted={JS.focus()}
          />

          <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
            Create an account
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: ServiceRadarWebNGWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)

    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    # Auto-create a tenant for new user registration (SaaS onboarding flow)
    user_params = ensure_tenant(user_params)

    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "An email was sent to #{user.email}, please access it to confirm your account."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end

  # Create or get a tenant for the user during registration.
  # For SaaS, each new user gets their own tenant by default.
  defp ensure_tenant(user_params) do
    if Map.has_key?(user_params, "tenant_id") or Map.has_key?(user_params, :tenant_id) do
      user_params
    else
      email = user_params["email"] || user_params[:email] || ""
      slug = email |> String.split("@") |> List.first() |> String.downcase()
      unique_slug = "#{slug}-#{System.unique_integer([:positive])}"

      # Create a new tenant for this user
      case create_tenant_for_user(unique_slug, email) do
        {:ok, tenant} ->
          Map.put(user_params, "tenant_id", tenant.id)

        {:error, _} ->
          user_params
      end
    end
  end

  defp create_tenant_for_user(slug, email) do
    alias ServiceRadar.Identity.Tenant

    # Use a system actor and bypass authorization for tenant creation during registration
    system_actor = %{
      id: "00000000-0000-0000-0000-000000000000",
      email: "system@serviceradar.local",
      role: :super_admin
    }

    Tenant
    |> Ash.Changeset.for_create(:create, %{
      name: "#{slug}'s Organization",
      slug: slug,
      contact_email: email
    }, actor: system_actor, authorize?: false)
    |> Ash.create(actor: system_actor, authorize?: false)
  end
end
