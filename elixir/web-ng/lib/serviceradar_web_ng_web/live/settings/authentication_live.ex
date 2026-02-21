defmodule ServiceRadarWebNGWeb.Settings.AuthenticationLive do
  @moduledoc """
  LiveView for configuring authentication settings.

  Allows administrators to configure:
  - Authentication mode (Password Only, Direct SSO, Gateway Proxy)
  - OIDC provider settings
  - SAML provider settings (future)
  - Gateway/Proxy JWT settings
  - Claim mappings
  """
  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNG.Authorization,
    resource_module: ServiceRadar.Identity.AuthSettings

  require Logger

  alias ServiceRadar.Identity.AuthSettings
  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.SettingsComponents

  @modes [
    {"Password Only", :password_only, "Users authenticate with email and password."},
    {"Direct SSO (OIDC/SAML)", :active_sso, "Users are redirected to an identity provider."},
    {"Gateway Proxy", :passive_proxy, "Authentication is handled by an API gateway."}
  ]

  @provider_types [
    {"OpenID Connect (OIDC)", :oidc},
    {"SAML 2.0", :saml}
  ]

  @impl true
  def event_mapping do
    Permit.Phoenix.LiveView.default_event_mapping()
    |> Map.merge(%{
      "save" => :update,
      "validate" => :read,
      "reset" => :update,
      "test_oidc" => :update,
      "test_saml" => :update
    })
  end

  @impl true
  def skip_preload do
    [:index, :read, :create, :update, :delete]
  end

  @impl true
  def handle_unauthorized(_action, socket) do
    socket =
      socket
      |> put_flash(:error, "You don't have permission to access Settings.")
      |> push_navigate(to: ~p"/analytics")

    {:halt, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <SettingsComponents.settings_shell current_path="/settings/authentication">
        <div class="space-y-4">
          <SettingsComponents.settings_nav
            current_path="/settings/authentication"
            current_scope={@current_scope}
          />
          <SettingsComponents.auth_nav
            current_path="/settings/authentication"
            current_scope={@current_scope}
          />
        </div>

        <div>
          <h1 class="text-2xl font-semibold text-base-content">Authentication Settings</h1>
          <p class="text-sm text-base-content/60">
            Configure how users authenticate to ServiceRadar.
          </p>
        </div>

        <%= if @loading do %>
          <div class="flex justify-center py-12">
            <span class="loading loading-spinner loading-lg"></span>
          </div>
        <% else %>
          <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-6">
            <.ui_panel>
              <:header>
                <div class="flex items-center justify-between w-full">
                  <div>
                    <div class="text-sm font-semibold">Status</div>
                    <p class="text-xs text-base-content/60">
                      Enable or disable SSO authentication.
                    </p>
                  </div>
                  <label class="label cursor-pointer gap-2">
                    <span class="label-text">Enabled</span>
                    <input
                      type="checkbox"
                      name="settings[is_enabled]"
                      checked={@form[:is_enabled].value}
                      class="toggle toggle-primary"
                    />
                  </label>
                </div>
              </:header>

              <%= if @form[:is_enabled].value do %>
                <div class="alert alert-success">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="stroke-current shrink-0 h-6 w-6"
                    fill="none"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  <span>SSO authentication is enabled.</span>
                </div>
              <% else %>
                <div class="alert">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    fill="none"
                    viewBox="0 0 24 24"
                    class="stroke-info shrink-0 w-6 h-6"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                    >
                    </path>
                  </svg>
                  <span>SSO is disabled. Users will authenticate with password only.</span>
                </div>
              <% end %>
            </.ui_panel>

            <.ui_panel>
              <:header>
                <div>
                  <div class="text-sm font-semibold">Authentication Mode</div>
                  <p class="text-xs text-base-content/60">
                    Select how users should authenticate.
                  </p>
                </div>
              </:header>

              <div class="space-y-3">
                <%= for {label, value, description} <- @modes do %>
                  <label class={"flex items-start gap-3 p-4 border rounded-lg cursor-pointer transition-colors #{if to_string(@form[:mode].value) == to_string(value), do: "border-primary bg-primary/5", else: "border-base-300 hover:border-primary/50"}"}>
                    <input
                      type="radio"
                      name="settings[mode]"
                      value={value}
                      checked={to_string(@form[:mode].value) == to_string(value)}
                      class="radio radio-primary mt-1"
                    />
                    <div>
                      <div class="font-medium">{label}</div>
                      <div class="text-sm text-base-content/60">{description}</div>
                    </div>
                  </label>
                <% end %>
              </div>
            </.ui_panel>

            <%= if to_string(@form[:mode].value) == "active_sso" do %>
              <.ui_panel>
                <:header>
                  <div>
                    <div class="text-sm font-semibold">Identity Provider Type</div>
                    <p class="text-xs text-base-content/60">
                      Select your SSO provider protocol.
                    </p>
                  </div>
                </:header>

                <div class="flex gap-4">
                  <%= for {label, value} <- @provider_types do %>
                    <label class={"flex items-center gap-2 p-3 border rounded-lg cursor-pointer transition-colors flex-1 #{if to_string(@form[:provider_type].value) == to_string(value), do: "border-primary bg-primary/5", else: "border-base-300 hover:border-primary/50"}"}>
                      <input
                        type="radio"
                        name="settings[provider_type]"
                        value={value}
                        checked={to_string(@form[:provider_type].value) == to_string(value)}
                        class="radio radio-primary"
                      />
                      <span>{label}</span>
                    </label>
                  <% end %>
                </div>
              </.ui_panel>

              <%= if to_string(@form[:provider_type].value) == "oidc" do %>
                <.oidc_config_panel form={@form} />
              <% end %>

              <%= if to_string(@form[:provider_type].value) == "saml" do %>
                <.saml_config_panel form={@form} />
              <% end %>

              <.ui_panel>
                <:header>
                  <div>
                    <div class="text-sm font-semibold">Password Fallback</div>
                    <p class="text-xs text-base-content/60">
                      Allow password login as a fallback when SSO is primary.
                    </p>
                  </div>
                </:header>

                <label class="label cursor-pointer justify-start gap-3">
                  <input
                    type="checkbox"
                    name="settings[allow_password_fallback]"
                    checked={@form[:allow_password_fallback].value}
                    class="checkbox checkbox-primary"
                  />
                  <span class="label-text">
                    Allow users to sign in with password in addition to SSO
                  </span>
                </label>
              </.ui_panel>
            <% end %>

            <%= if to_string(@form[:mode].value) == "passive_proxy" do %>
              <.proxy_config_panel form={@form} />
            <% end %>

            <.claim_mappings_panel form={@form} />

            <div class="flex justify-end gap-3">
              <button type="button" phx-click="reset" class="btn btn-ghost">
                Reset
              </button>
              <button type="submit" class="btn btn-primary" phx-disable-with="Saving...">
                Save Configuration
              </button>
            </div>
          </.form>
        <% end %>
      </SettingsComponents.settings_shell>
    </Layouts.app>
    """
  end

  defp oidc_config_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">OIDC Configuration</div>
          <p class="text-xs text-base-content/60">
            Configure your OpenID Connect identity provider.
          </p>
        </div>
      </:header>

      <div class="space-y-4">
        <div class="form-control">
          <label class="label">
            <span class="label-text">Discovery URL</span>
          </label>
          <input
            type="url"
            name="settings[oidc_discovery_url]"
            value={@form[:oidc_discovery_url].value}
            class="input input-bordered w-full"
            placeholder="https://login.example.com/.well-known/openid-configuration"
          />
          <label class="label">
            <span class="label-text-alt">The OpenID Connect discovery endpoint URL</span>
          </label>
        </div>

        <div class="grid grid-cols-2 gap-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Client ID</span>
            </label>
            <input
              type="text"
              name="settings[oidc_client_id]"
              value={@form[:oidc_client_id].value}
              class="input input-bordered w-full"
              placeholder="your-client-id"
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Client Secret</span>
            </label>
            <input
              type="password"
              name="settings[oidc_client_secret]"
              value={@form[:oidc_client_secret].value}
              class="input input-bordered w-full"
              placeholder="••••••••"
            />
            <label class="label">
              <span class="label-text-alt">Leave blank to keep existing secret</span>
            </label>
          </div>
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text">Scopes</span>
          </label>
          <input
            type="text"
            name="settings[oidc_scopes]"
            value={@form[:oidc_scopes].value}
            class="input input-bordered w-full"
            placeholder="openid profile email"
          />
          <label class="label">
            <span class="label-text-alt">Space-separated list of OAuth scopes</span>
          </label>
        </div>

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
            <div class="font-medium">Redirect URI</div>
            <code class="text-xs">{ServiceRadarWebNGWeb.Endpoint.url()}/auth/oidc/callback</code>
            <div class="text-xs mt-1">Add this to your IdP's allowed redirect URIs.</div>
          </div>
        </div>

        <div class="flex items-center gap-3">
          <button
            type="button"
            phx-click="test_oidc"
            class="btn btn-outline btn-sm"
            disabled={!@form[:oidc_discovery_url].value || @form[:oidc_discovery_url].value == ""}
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-4 w-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            </svg>
            Test Configuration
          </button>
          <span class="text-xs text-base-content/60">Verify the discovery URL is accessible</span>
        </div>
      </div>
    </.ui_panel>
    """
  end

  defp saml_config_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">SAML Configuration</div>
          <p class="text-xs text-base-content/60">
            Configure your SAML 2.0 identity provider.
          </p>
        </div>
      </:header>

      <div class="space-y-4">
        <%!-- SP Information for IdP Configuration --%>
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
          <div class="space-y-2 text-sm">
            <div class="font-medium">Configure these values in your Identity Provider:</div>
            <div class="grid grid-cols-1 gap-2">
              <div>
                <span class="font-medium">Entity ID (SP): </span>
                <code class="bg-base-300 px-1 rounded text-xs">
                  {ServiceRadarWebNGWeb.Endpoint.url()}
                </code>
              </div>
              <div>
                <span class="font-medium">ACS URL: </span>
                <code class="bg-base-300 px-1 rounded text-xs">
                  {ServiceRadarWebNGWeb.Endpoint.url()}/auth/saml/consume
                </code>
              </div>
              <div>
                <span class="font-medium">SP Metadata URL: </span>
                <a
                  href={ServiceRadarWebNGWeb.Endpoint.url() <> "/auth/saml/metadata"}
                  target="_blank"
                  class="link link-primary text-xs"
                >
                  {ServiceRadarWebNGWeb.Endpoint.url()}/auth/saml/metadata
                </a>
              </div>
            </div>
          </div>
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text">SP Entity ID</span>
          </label>
          <input
            type="text"
            name="settings[saml_sp_entity_id]"
            value={@form[:saml_sp_entity_id].value || ServiceRadarWebNGWeb.Endpoint.url()}
            class="input input-bordered w-full"
            placeholder={ServiceRadarWebNGWeb.Endpoint.url()}
          />
          <label class="label">
            <span class="label-text-alt">Service Provider entity ID (defaults to base URL)</span>
          </label>
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text">IdP Metadata URL</span>
          </label>
          <input
            type="url"
            name="settings[saml_idp_metadata_url]"
            value={@form[:saml_idp_metadata_url].value}
            class="input input-bordered w-full"
            placeholder="https://idp.example.com/federationmetadata/2007-06/federationmetadata.xml"
          />
          <label class="label">
            <span class="label-text-alt">URL to fetch IdP metadata XML (preferred)</span>
          </label>
        </div>

        <div class="divider text-xs text-base-content/60">OR</div>

        <div class="form-control">
          <label class="label">
            <span class="label-text">IdP Metadata XML</span>
          </label>
          <textarea
            name="settings[saml_idp_metadata_xml]"
            class="textarea textarea-bordered w-full h-32 font-mono text-xs"
            placeholder="Paste IdP metadata XML here..."
          ><%= @form[:saml_idp_metadata_xml].value %></textarea>
          <label class="label">
            <span class="label-text-alt">Alternative: paste the IdP metadata XML directly</span>
          </label>
        </div>

        <div class="alert">
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
              d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
            >
            </path>
          </svg>
          <div class="text-sm">
            <div class="font-medium">Expected SAML Response Format:</div>
            <ul class="list-disc list-inside text-xs mt-1 space-y-1">
              <li>NameID format: <code class="bg-base-300 px-1 rounded">emailAddress</code></li>
              <li>Binding: <code class="bg-base-300 px-1 rounded">HTTP-POST</code></li>
              <li>Signed assertions required</li>
            </ul>
          </div>
        </div>

        <div class="flex items-center gap-3">
          <button
            type="button"
            phx-click="test_saml"
            class="btn btn-outline btn-sm"
            disabled={
              (!@form[:saml_idp_metadata_url].value || @form[:saml_idp_metadata_url].value == "") &&
                (!@form[:saml_idp_metadata_xml].value || @form[:saml_idp_metadata_xml].value == "")
            }
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-4 w-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            </svg>
            Test Configuration
          </button>
          <span class="text-xs text-base-content/60">Verify the IdP metadata is valid</span>
        </div>
      </div>
    </.ui_panel>
    """
  end

  defp proxy_config_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">Gateway/Proxy JWT Configuration</div>
          <p class="text-xs text-base-content/60">
            Configure JWT validation for API gateway authentication.
          </p>
        </div>
      </:header>

      <div class="space-y-4">
        <div class="form-control">
          <label class="label">
            <span class="label-text">JWT Header Name</span>
          </label>
          <input
            type="text"
            name="settings[jwt_header_name]"
            value={@form[:jwt_header_name].value || "Authorization"}
            class="input input-bordered w-full"
            placeholder="Authorization"
          />
          <label class="label">
            <span class="label-text-alt">
              The HTTP header containing the JWT (default: Authorization)
            </span>
          </label>
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text">JWKS URL</span>
          </label>
          <input
            type="url"
            name="settings[jwt_jwks_url]"
            value={@form[:jwt_jwks_url].value}
            class="input input-bordered w-full"
            placeholder="https://gateway.example.com/.well-known/jwks.json"
          />
          <label class="label">
            <span class="label-text-alt">
              URL to fetch JSON Web Key Set for signature verification
            </span>
          </label>
        </div>

        <div class="divider text-xs text-base-content/60">OR</div>

        <div class="form-control">
          <label class="label">
            <span class="label-text">Public Key (PEM)</span>
          </label>
          <textarea
            name="settings[jwt_public_key_pem]"
            class="textarea textarea-bordered w-full h-32 font-mono text-xs"
            placeholder="-----BEGIN PUBLIC KEY-----&#10;...&#10;-----END PUBLIC KEY-----"
          ><%= @form[:jwt_public_key_pem].value %></textarea>
          <label class="label">
            <span class="label-text-alt">Alternative to JWKS: paste the public key directly</span>
          </label>
        </div>

        <div class="grid grid-cols-2 gap-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Expected Issuer</span>
            </label>
            <input
              type="text"
              name="settings[jwt_issuer]"
              value={@form[:jwt_issuer].value}
              class="input input-bordered w-full"
              placeholder="https://gateway.example.com"
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Expected Audience</span>
            </label>
            <input
              type="text"
              name="settings[jwt_audience]"
              value={@form[:jwt_audience].value}
              class="input input-bordered w-full"
              placeholder="serviceradar-api"
            />
          </div>
        </div>
      </div>
    </.ui_panel>
    """
  end

  defp claim_mappings_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">Claim Mappings</div>
          <p class="text-xs text-base-content/60">
            Map JWT/SAML claims to user attributes.
          </p>
        </div>
      </:header>

      <div class="space-y-4">
        <div class="grid grid-cols-3 gap-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Email Claim</span>
            </label>
            <input
              type="text"
              name="settings[claim_email]"
              value={get_claim_mapping(@form, "email", "email")}
              class="input input-bordered w-full"
              placeholder="email"
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Name Claim</span>
            </label>
            <input
              type="text"
              name="settings[claim_name]"
              value={get_claim_mapping(@form, "name", "name")}
              class="input input-bordered w-full"
              placeholder="name"
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Subject Claim</span>
            </label>
            <input
              type="text"
              name="settings[claim_sub]"
              value={get_claim_mapping(@form, "sub", "sub")}
              class="input input-bordered w-full"
              placeholder="sub"
            />
          </div>
        </div>

        <label class="label">
          <span class="label-text-alt">Use dot notation for nested claims (e.g., "user.email")</span>
        </label>
      </div>
    </.ui_panel>
    """
  end

  defp get_claim_mapping(form, key, default) do
    mappings = form[:claim_mappings].value || %{}
    Map.get(mappings, key, default)
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if ServiceRadarWebNG.RBAC.can?(scope, "settings.auth.manage") do
      socket =
        socket
        |> assign(:loading, true)
        |> assign(:modes, @modes)
        |> assign(:provider_types, @provider_types)
        |> assign(:form, nil)

      # Load settings asynchronously
      send(self(), :load_settings)

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Settings.")
       |> push_navigate(to: ~p"/analytics")}
    end
  end

  @impl true
  def handle_info(:load_settings, socket) do
    user = socket.assigns.current_scope.user

    settings = load_or_create_settings(user)
    form_data = settings_to_form_data(settings)

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:settings, settings)
     |> assign(:form, to_form(form_data, as: :settings))}
  end

  @impl true
  def handle_event("validate", %{"settings" => params}, socket) do
    form_data = merge_form_params(socket.assigns.form.source, params)
    {:noreply, assign(socket, :form, to_form(form_data, as: :settings))}
  end

  def handle_event("save", %{"settings" => params}, socket) do
    user = socket.assigns.current_scope.user
    settings = socket.assigns.settings

    # Build the update params
    update_params = build_update_params(params)

    # Validate configuration if SSO is being enabled
    case validate_before_enable(params, update_params) do
      :ok ->
        case update_settings(settings, update_params, user) do
          {:ok, updated_settings} ->
            # Invalidate the config cache
            ConfigCache.invalidate()

            {:noreply,
             socket
             |> assign(:settings, updated_settings)
             |> assign(:form, to_form(settings_to_form_data(updated_settings), as: :settings))
             |> put_flash(:info, "Authentication settings saved successfully.")}

          {:error, error} ->
            Logger.error("Failed to save auth settings: #{inspect(error)}")

            {:noreply,
             socket
             |> put_flash(:error, "Failed to save settings. Please check your configuration.")}
        end

      {:error, message} ->
        {:noreply,
         socket
         |> put_flash(:error, message)}
    end
  end

  def handle_event("reset", _params, socket) do
    settings = socket.assigns.settings
    form_data = settings_to_form_data(settings)

    {:noreply,
     socket
     |> assign(:form, to_form(form_data, as: :settings))
     |> put_flash(:info, "Form reset to saved values.")}
  end

  def handle_event("test_oidc", _params, socket) do
    discovery_url = socket.assigns.form.source["oidc_discovery_url"]

    if discovery_url && discovery_url != "" do
      case test_oidc_discovery(discovery_url) do
        {:ok, endpoints} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "OIDC configuration valid. Found endpoints: #{Enum.join(endpoints, ", ")}"
           )}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "OIDC configuration test failed: #{reason}")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Please enter a discovery URL first.")}
    end
  end

  def handle_event("test_saml", _params, socket) do
    metadata_url = socket.assigns.form.source["saml_idp_metadata_url"]
    metadata_xml = socket.assigns.form.source["saml_idp_metadata_xml"]

    cond do
      metadata_url && metadata_url != "" ->
        case test_saml_metadata_url(metadata_url) do
          {:ok, entity_id} ->
            {:noreply,
             socket
             |> put_flash(:info, "SAML metadata valid. IdP Entity ID: #{entity_id}")}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "SAML metadata test failed: #{reason}")}
        end

      metadata_xml && metadata_xml != "" ->
        case test_saml_metadata_xml(metadata_xml) do
          {:ok, entity_id} ->
            {:noreply,
             socket
             |> put_flash(:info, "SAML metadata XML valid. IdP Entity ID: #{entity_id}")}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "SAML metadata XML invalid: #{reason}")}
        end

      true ->
        {:noreply,
         socket
         |> put_flash(:error, "Please enter a metadata URL or paste metadata XML first.")}
    end
  end

  # Validate OIDC/SAML configuration before enabling
  defp validate_before_enable(params, update_params) do
    is_enabling = params["is_enabled"] == "true"
    mode = update_params[:mode]
    provider_type = update_params[:provider_type]

    cond do
      # Only validate when enabling SSO
      not is_enabling ->
        :ok

      mode != :active_sso ->
        :ok

      provider_type == :oidc ->
        validate_oidc_config(params)

      provider_type == :saml ->
        validate_saml_config(params)

      true ->
        :ok
    end
  end

  defp validate_oidc_config(params) do
    discovery_url = params["oidc_discovery_url"]
    client_id = params["oidc_client_id"]

    cond do
      is_nil(discovery_url) or discovery_url == "" ->
        {:error, "OIDC Discovery URL is required to enable SSO."}

      is_nil(client_id) or client_id == "" ->
        {:error, "OIDC Client ID is required to enable SSO."}

      true ->
        # Validate the discovery URL is accessible
        case test_oidc_discovery(discovery_url) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            {:error,
             "OIDC configuration validation failed: #{reason}. Please verify your settings and try again."}
        end
    end
  end

  defp validate_saml_config(params) do
    metadata_url = params["saml_idp_metadata_url"]
    metadata_xml = params["saml_idp_metadata_xml"]

    has_url = metadata_url && metadata_url != ""
    has_xml = metadata_xml && metadata_xml != ""

    case {has_url, has_xml} do
      {false, false} ->
        {:error, "SAML IdP metadata (URL or XML) is required to enable SSO."}

      {true, _} ->
        validate_saml_metadata_url(metadata_url)

      {false, true} ->
        validate_saml_metadata_xml(metadata_xml)
    end
  end

  defp validate_saml_metadata_url(url) do
    case test_saml_metadata_url(url) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error,
         "SAML metadata validation failed: #{reason}. Please verify your settings and try again."}
    end
  end

  defp validate_saml_metadata_xml(xml) do
    case test_saml_metadata_xml(xml) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "SAML metadata XML validation failed: #{reason}"}
    end
  end

  defp test_oidc_discovery(url) do
    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        # Check for required OIDC endpoints
        required = ["authorization_endpoint", "token_endpoint", "issuer"]
        found = Enum.filter(required, &Map.has_key?(body, &1))

        if length(found) == length(required) do
          {:ok, found}
        else
          missing = required -- found
          {:error, "Missing required endpoints: #{Enum.join(missing, ", ")}"}
        end

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        # Try to parse as JSON
        case Jason.decode(body) do
          {:ok, parsed} ->
            test_oidc_discovery_body(parsed)

          {:error, _} ->
            {:error, "Response is not valid JSON"}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} response"}

      {:error, %{reason: reason}} ->
        {:error, "Connection failed: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp test_oidc_discovery_body(body) when is_map(body) do
    required = ["authorization_endpoint", "token_endpoint", "issuer"]
    found = Enum.filter(required, &Map.has_key?(body, &1))

    if length(found) == length(required) do
      {:ok, found}
    else
      missing = required -- found
      {:error, "Missing required endpoints: #{Enum.join(missing, ", ")}"}
    end
  end

  defp test_saml_metadata_url(url) do
    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        test_saml_metadata_xml(body)

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} response"}

      {:error, %{reason: reason}} ->
        {:error, "Connection failed: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp test_saml_metadata_xml(xml) do
    try do
      import SweetXml

      # Try to extract entity ID
      entity_id =
        xml
        |> xpath(
          ~x"//md:EntityDescriptor/@entityID"s,
          namespace_conformant: true,
          namespaces: [md: "urn:oasis:names:tc:SAML:2.0:metadata"]
        )

      # Fallback without namespace
      entity_id =
        if entity_id == "" do
          xpath(xml, ~x"//EntityDescriptor/@entityID"s)
        else
          entity_id
        end

      if entity_id != "" do
        {:ok, entity_id}
      else
        {:error, "Could not find EntityDescriptor with entityID"}
      end
    rescue
      e ->
        Logger.error("SAML metadata parse error: #{inspect(e)}")
        {:error, "Failed to parse XML metadata"}
    end
  end

  defp load_or_create_settings(user) do
    case AuthSettings.get_settings(actor: user) do
      {:ok, settings} ->
        settings

      {:error, _} ->
        # Create default settings
        case AuthSettings.create(%{mode: :password_only}, actor: user) do
          {:ok, settings} -> settings
          {:error, _} -> %{mode: :password_only, is_enabled: false}
        end
    end
  end

  defp settings_to_form_data(settings) when is_map(settings) do
    %{
      "is_enabled" => Map.get(settings, :is_enabled, false),
      "mode" => Map.get(settings, :mode, :password_only),
      "provider_type" => Map.get(settings, :provider_type),
      "allow_password_fallback" => Map.get(settings, :allow_password_fallback, true),
      # OIDC settings
      "oidc_discovery_url" => Map.get(settings, :oidc_discovery_url),
      "oidc_client_id" => Map.get(settings, :oidc_client_id),
      "oidc_client_secret" => "",
      "oidc_scopes" => Map.get(settings, :oidc_scopes, "openid profile email"),
      # SAML settings
      "saml_sp_entity_id" => Map.get(settings, :saml_sp_entity_id),
      "saml_idp_metadata_url" => Map.get(settings, :saml_idp_metadata_url),
      "saml_idp_metadata_xml" => Map.get(settings, :saml_idp_metadata_xml),
      # JWT/Proxy settings
      "jwt_header_name" => Map.get(settings, :jwt_header_name, "Authorization"),
      "jwt_jwks_url" => Map.get(settings, :jwt_jwks_url),
      "jwt_public_key_pem" => Map.get(settings, :jwt_public_key_pem),
      "jwt_issuer" => Map.get(settings, :jwt_issuer),
      "jwt_audience" => Map.get(settings, :jwt_audience),
      "claim_mappings" =>
        Map.get(settings, :claim_mappings, %{"email" => "email", "name" => "name", "sub" => "sub"})
    }
  end

  defp merge_form_params(existing, new_params) do
    existing
    |> Map.merge(new_params)
    |> Map.put(
      "is_enabled",
      new_params["is_enabled"] == "true" || new_params["is_enabled"] == true
    )
    |> Map.put(
      "allow_password_fallback",
      new_params["allow_password_fallback"] == "true" ||
        new_params["allow_password_fallback"] == true
    )
  end

  defp build_update_params(params) do
    base = %{
      is_enabled: params["is_enabled"] == "true",
      mode: String.to_existing_atom(params["mode"] || "password_only"),
      allow_password_fallback: params["allow_password_fallback"] == "true"
    }

    base =
      if params["provider_type"] && params["provider_type"] != "" do
        Map.put(base, :provider_type, String.to_existing_atom(params["provider_type"]))
      else
        base
      end

    # OIDC settings
    base =
      base
      |> maybe_put(:oidc_discovery_url, params["oidc_discovery_url"])
      |> maybe_put(:oidc_client_id, params["oidc_client_id"])
      |> maybe_put(:oidc_scopes, params["oidc_scopes"])

    # Only update secret if provided
    base =
      if params["oidc_client_secret"] && params["oidc_client_secret"] != "" do
        Map.put(base, :oidc_client_secret, params["oidc_client_secret"])
      else
        base
      end

    # SAML settings
    base =
      base
      |> maybe_put(:saml_sp_entity_id, params["saml_sp_entity_id"])
      |> maybe_put(:saml_idp_metadata_url, params["saml_idp_metadata_url"])
      |> maybe_put(:saml_idp_metadata_xml, params["saml_idp_metadata_xml"])

    # JWT/Proxy settings
    base =
      base
      |> maybe_put(:jwt_header_name, params["jwt_header_name"])
      |> maybe_put(:jwt_jwks_url, params["jwt_jwks_url"])
      |> maybe_put(:jwt_public_key_pem, params["jwt_public_key_pem"])
      |> maybe_put(:jwt_issuer, params["jwt_issuer"])
      |> maybe_put(:jwt_audience, params["jwt_audience"])

    # Claim mappings
    claim_mappings = %{
      "email" => params["claim_email"] || "email",
      "name" => params["claim_name"] || "name",
      "sub" => params["claim_sub"] || "sub"
    }

    Map.put(base, :claim_mappings, claim_mappings)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp update_settings(settings, params, user) when is_struct(settings) do
    AuthSettings.update(settings, params, actor: user)
  end

  defp update_settings(_settings, params, user) do
    # Settings is a map (not loaded from DB), create new
    AuthSettings.create(params, actor: user)
  end
end
