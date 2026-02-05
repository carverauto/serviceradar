defmodule ServiceRadarWebNGWeb.Settings.AuthorizationLive do
  @moduledoc """
  Admin authorization settings view (default role + role mappings).
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNG.Authorization,
    resource_module: ServiceRadar.Identity.AuthorizationSettings

  alias ServiceRadarWebNG.AdminApi
  alias ServiceRadarWebNGWeb.SettingsComponents

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :page_title, "Authorization Settings")
    scope = socket.assigns.current_scope

    {settings, settings_flash} =
      case get_or_create_settings(scope) do
        {:ok, settings} -> {settings, nil}
        {:error, error} -> {%{default_role: :viewer, role_mappings: []}, format_ash_error(error)}
      end

    {:ok,
     socket
     |> assign(:settings, settings)
     |> assign(:form, to_form(settings_form(settings), as: :settings))
     |> assign(:json_error, nil)
     |> maybe_put_flash(settings_flash)}
  end

  @impl true
  def handle_event("validate", %{"settings" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :settings))}
  end

  def handle_event("save", %{"settings" => params}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, attrs} <- normalize_attrs(params),
         {:ok, updated} <- AdminApi.update_authorization_settings(scope, attrs) do
      {:noreply,
       socket
       |> assign(:settings, updated)
       |> assign(:form, to_form(settings_form(updated), as: :settings))
       |> assign(:json_error, nil)
       |> put_flash(:info, "Authorization settings updated")}
    else
      {:error, :invalid_role} ->
        {:noreply, put_flash(socket, :error, "Default role must be viewer, operator, or admin")}

      {:error, :invalid_json} ->
        {:noreply, assign(socket, :json_error, "Role mappings must be valid JSON")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  @impl true
  def event_mapping do
    Permit.Phoenix.LiveView.default_event_mapping()
    |> Map.merge(%{"save" => :update, "validate" => :read})
  end

  @impl true
  def skip_preload do
    [:index, :read, :create, :update, :delete]
  end

  @impl true
  def handle_unauthorized(_action, socket) do
    socket =
      socket
      |> put_flash(:error, "Admin access required")
      |> push_navigate(to: ~p"/settings/profile")

    {:halt, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <SettingsComponents.settings_shell current_path="/settings/auth/authorization">
        <div class="space-y-4">
          <SettingsComponents.settings_nav
            current_path="/settings/auth/authorization"
            current_scope={@current_scope}
          />
          <SettingsComponents.auth_nav
            current_path="/settings/auth/authorization"
            current_scope={@current_scope}
          />
        </div>

        <div class="grid gap-6 lg:grid-cols-[1fr,1fr]">
          <section class="space-y-4">
            <div>
              <h1 class="text-xl font-semibold">Authorization</h1>
              <p class="text-sm text-base-content/60">
                Control default roles and IdP role mapping behavior.
              </p>
            </div>

            <.form for={@form} id="authorization-form" phx-change="validate" phx-submit="save">
              <div class="space-y-4">
                <.input
                  field={@form[:default_role]}
                  type="select"
                  label="Default Role"
                  options={[{"viewer", "viewer"}, {"operator", "operator"}, {"admin", "admin"}]}
                />

                <div>
                  <label class="label">
                    <span class="label-text">Role Mappings (JSON)</span>
                  </label>
                  <textarea
                    name="settings[role_mappings]"
                    class="textarea textarea-bordered w-full min-h-[200px]"
                  ><%= @form[:role_mappings].value %></textarea>
                  <%= if @json_error do %>
                    <div class="text-xs text-error mt-2">{@json_error}</div>
                  <% else %>
                    <div class="text-xs text-base-content/60 mt-2">
                      Provide a JSON array of mapping objects (e.g. group to role).
                    </div>
                  <% end %>
                </div>
              </div>

              <div class="mt-6">
                <button class="btn btn-primary" type="submit">Save Settings</button>
              </div>
            </.form>
          </section>

          <section class="space-y-4">
            <div class="rounded-xl border border-base-200 bg-base-100 p-4">
              <h2 class="text-sm font-semibold">Example Mapping</h2>
              <p class="text-xs text-base-content/60 mt-1">
                Use IdP claims to assign roles automatically.
              </p>
              <pre class="mt-3 rounded-lg bg-base-200/60 p-3 text-xs" phx-no-curly-interpolation>
                [
                  {"source": "groups", "value": "Network Ops", "role": "operator"},
                  {"source": "email_domain", "value": "example.com", "role": "admin"}
                ]
              </pre>
            </div>
          </section>
        </div>
      </SettingsComponents.settings_shell>
    </Layouts.app>
    """
  end

  defp get_or_create_settings(scope) do
    AdminApi.get_authorization_settings(scope)
  end

  defp normalize_attrs(params) do
    with {:ok, default_role} <- normalize_role(params["default_role"]),
         {:ok, role_mappings} <- decode_role_mappings(params["role_mappings"]) do
      attrs = %{}

      attrs =
        if is_nil(default_role) do
          attrs
        else
          Map.put(attrs, :default_role, default_role)
        end

      attrs = Map.put(attrs, :role_mappings, role_mappings)

      {:ok, attrs}
    end
  end

  defp normalize_role(nil), do: {:ok, nil}
  defp normalize_role(""), do: {:ok, nil}
  defp normalize_role("viewer"), do: {:ok, :viewer}
  defp normalize_role("operator"), do: {:ok, :operator}
  defp normalize_role("admin"), do: {:ok, :admin}
  defp normalize_role(_), do: {:error, :invalid_role}

  defp decode_role_mappings(nil), do: {:ok, []}
  defp decode_role_mappings(""), do: {:ok, []}

  defp decode_role_mappings(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_json}
    end
  end

  defp settings_form(settings) do
    %{
      "default_role" => Atom.to_string(settings.default_role || :viewer),
      "role_mappings" => Jason.encode!(settings.role_mappings || [], pretty: true)
    }
  end

  defp maybe_put_flash(socket, nil), do: socket
  defp maybe_put_flash(socket, message), do: put_flash(socket, :error, message)

  defp format_ash_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", fn
      %{message: message} -> message
      _ -> "Validation error"
    end)
  end

  defp format_ash_error({:http_error, status, body}) do
    message =
      case body do
        %{"error" => error} -> error
        %{"message" => error} -> error
        _ -> "Request failed"
      end

    "HTTP #{status}: #{message}"
  end

  defp format_ash_error(_), do: "Unexpected error"
end
