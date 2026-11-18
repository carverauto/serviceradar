defmodule ServiceRadarWebNGWeb.WebPropertyLive.Show do
  @moduledoc """
  Detail, posture, RUM key rotation, infrastructure binding, and synthetic check
  LiveView for a single L7 `WebProperty` (`/websites/:id`).
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Inventory.WebProperty
  alias ServiceRadar.Inventory.WebPropertyBinding
  alias ServiceRadar.Inventory.WebPropertyPubSub
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:current_scope]
    can_view = RBAC.can?(scope, "devices.view")
    can_manage = RBAC.can?(scope, "settings.networks.manage")

    if connected?(socket) do
      WebPropertyPubSub.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Website Details")
     |> assign(:can_view, can_view)
     |> assign(:can_manage, can_manage)
     |> assign(:web_property_id, nil)
     |> assign(:web_property, nil)
     |> assign(:error, nil)
     |> assign(:form_error, nil)
     |> assign(:binding_error, nil)
     |> assign(:editing?, false)
     |> assign(:edit_form, nil)
     |> assign(:binding_form, default_binding_form())
     |> assign(:bindings_count, 0)
     |> assign(:service_checks_count, 0)
     |> assign(:synthetic_assignments, [])
     |> assign(:srql, %{enabled: false, page_path: "/websites"})
     |> stream_configure(:bindings, dom_id: &"binding-#{&1.id}")
     |> stream_configure(:service_checks, dom_id: &"service-check-#{&1.id}")
     |> stream(:bindings, [])
     |> stream(:service_checks, [])}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    if socket.assigns.can_view do
      socket =
        socket
        |> assign(:web_property_id, id)
        |> assign(:srql, %{enabled: false, page_path: "/websites/#{id}"})

      if connected?(socket) do
        {:noreply, load_property(socket, id)}
      else
        {:noreply, socket}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "You do not have permission to view websites.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("toggle_edit", _params, socket) do
    if socket.assigns.can_manage and socket.assigns.web_property do
      editing? = not socket.assigns.editing?

      edit_form =
        if editing? do
          edit_form_for(socket.assigns.web_property)
        else
          socket.assigns.edit_form
        end

      {:noreply,
       socket
       |> assign(:editing?, editing?)
       |> assign(:form_error, nil)
       |> assign(:edit_form, edit_form)}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to edit websites.")}
    end
  end

  def handle_event("save_web_property", %{"web_property" => params}, socket) do
    scope = socket.assigns[:current_scope]

    with true <- RBAC.can?(scope, "settings.networks.manage"),
         %WebProperty{} = wp <- socket.assigns.web_property do
      attrs = parse_update_attrs(params)

      case wp
           |> Ash.Changeset.for_update(:update, attrs)
           |> Ash.update(scope: scope) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:web_property, updated)
           |> assign(:page_title, updated.name)
           |> assign(:editing?, false)
           |> assign(:form_error, nil)
           |> assign(:edit_form, edit_form_for(updated))
           |> put_flash(:info, "Web property updated.")}

        {:error, error} ->
          {:noreply,
           socket
           |> assign(:form_error, format_ash_error(error))
           |> assign(:edit_form, to_form(params, as: :web_property))}
      end
    else
      _ ->
        {:noreply, put_flash(socket, :error, "You do not have permission to update websites.")}
    end
  end

  def handle_event("delete_web_property", _params, socket) do
    scope = socket.assigns[:current_scope]

    with true <- RBAC.can?(scope, "settings.networks.manage"),
         %WebProperty{} = wp <- socket.assigns.web_property do
      case Ash.destroy(wp, scope: scope) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, "Web property deleted.")
           |> push_navigate(to: ~p"/websites")}

        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Web property deleted.")
           |> push_navigate(to: ~p"/websites")}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, "Failed to delete web property: #{format_ash_error(error)}")}
      end
    else
      _ ->
        {:noreply, put_flash(socket, :error, "You do not have permission to delete websites.")}
    end
  end

  def handle_event("rotate_rum_site_key", _params, socket) do
    scope = socket.assigns[:current_scope]

    with true <- RBAC.can?(scope, "settings.networks.manage"),
         %WebProperty{} = wp <- socket.assigns.web_property do
      case wp
           |> Ash.Changeset.for_update(:rotate_rum_site_key, %{})
           |> Ash.update(scope: scope) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:web_property, updated)
           |> put_flash(:info, "RUM site key rotated. Previous key is now invalidated.")}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, "Failed to rotate site key: #{format_ash_error(error)}")}
      end
    else
      _ ->
        {:noreply, put_flash(socket, :error, "You do not have permission to rotate RUM keys.")}
    end
  end

  def handle_event("copy_value", %{"value" => text}, socket) when is_binary(text) do
    {:noreply, push_event(socket, "clipboard", %{text: text})}
  end

  def handle_event("create_binding", %{"binding" => params}, socket) do
    scope = socket.assigns[:current_scope]

    with true <- RBAC.can?(scope, "settings.networks.manage"),
         %WebProperty{} = wp <- socket.assigns.web_property do
      attrs = build_binding_attrs(wp.id, params)

      case WebPropertyBinding
           |> Ash.Changeset.for_create(:create, attrs)
           |> Ash.create(scope: scope) do
        {:ok, _binding} ->
          {:noreply,
           socket
           |> assign(:binding_error, nil)
           |> assign(:binding_form, default_binding_form())
           |> reload_bindings(wp.id, scope)
           |> put_flash(:info, "Infrastructure binding added.")}

        {:error, error} ->
          {:noreply,
           socket
           |> assign(:binding_error, format_ash_error(error))
           |> assign(:binding_form, to_form(params, as: :binding))}
      end
    else
      _ ->
        {:noreply, put_flash(socket, :error, "You do not have permission to manage bindings.")}
    end
  end

  def handle_event("delete_binding", %{"id" => binding_id}, socket) do
    scope = socket.assigns[:current_scope]

    with true <- RBAC.can?(scope, "settings.networks.manage"),
         %WebProperty{} = wp <- socket.assigns.web_property,
         {:ok, binding} <-
           WebPropertyBinding
           |> Ash.Query.filter(id == ^binding_id and web_property_id == ^wp.id)
           |> Ash.read_one(scope: scope),
         false <- is_nil(binding) do
      case Ash.destroy(binding, scope: scope) do
        :ok ->
          {:noreply,
           socket
           |> reload_bindings(wp.id, scope)
           |> put_flash(:info, "Binding removed.")}

        {:ok, _} ->
          {:noreply,
           socket
           |> reload_bindings(wp.id, scope)
           |> put_flash(:info, "Binding removed.")}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, "Failed to remove binding: #{format_ash_error(error)}")}
      end
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Unable to remove binding.")}
    end
  end

  @impl true
  def handle_info({:web_property_updated, id, _record}, socket) do
    if connected?(socket) and socket.assigns.web_property_id == id do
      {:noreply, load_property(socket, id)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:web_property_deleted, id}, socket) do
    if connected?(socket) and socket.assigns.web_property_id == id do
      {:noreply,
       socket
       |> put_flash(:info, "This web property was deleted.")
       |> push_navigate(to: ~p"/websites")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_property(socket, id) do
    scope = socket.assigns[:current_scope]

    with true <- valid_uuid?(id),
         {:ok, %WebProperty{} = wp} <- WebProperty.get_by_id(id, scope: scope) do
      bindings = load_bindings(wp.id, scope)
      checks = load_service_checks(wp.id, scope)
      synthetic = load_synthetic_assignments(wp.id, scope)
      apply_property_state(socket, wp, bindings, checks, synthetic)
    else
      _ ->
        socket
        |> assign(:web_property, nil)
        |> assign(:error, "Web property not found")
        |> assign(:bindings_count, 0)
        |> assign(:service_checks_count, 0)
        |> assign(:synthetic_assignments, [])
        |> stream(:bindings, [], reset: true)
        |> stream(:service_checks, [], reset: true)
    end
  end

  @doc false
  def apply_property_state(socket, %WebProperty{} = wp, bindings, checks, synthetic) do
    edit_form =
      if socket.assigns[:editing?] && not is_nil(socket.assigns[:edit_form]) do
        socket.assigns.edit_form
      else
        edit_form_for(wp)
      end

    socket
    |> assign(:page_title, wp.name)
    |> assign(:web_property, wp)
    |> assign(:error, nil)
    |> assign(:edit_form, edit_form)
    |> assign(:bindings_count, length(bindings))
    |> stream(:bindings, bindings, reset: true)
    |> assign(:service_checks_count, length(checks))
    |> stream(:service_checks, checks, reset: true)
    |> assign(:synthetic_assignments, synthetic)
  end

  defp reload_bindings(socket, web_property_id, scope) do
    bindings = load_bindings(web_property_id, scope)

    socket
    |> assign(:bindings_count, length(bindings))
    |> stream(:bindings, bindings, reset: true)
  end

  defp load_bindings(web_property_id, scope) do
    case WebPropertyBinding.list_by_web_property(web_property_id, scope: scope) do
      {:ok, list} -> list
      _ -> []
    end
  end

  defp load_service_checks(web_property_id, scope) do
    if RBAC.can?(scope, "services.view") do
      case ServiceCheck
           |> Ash.Query.for_read(:by_web_property, %{web_property_id: web_property_id})
           |> Ash.read(scope: scope) do
        {:ok, list} -> list
        _ -> []
      end
    else
      []
    end
  end

  defp load_synthetic_assignments(web_property_id, scope) do
    if RBAC.can?(scope, "plugins.view") do
      case PluginAssignment
           |> Ash.Query.filter(plugin_id == "http-synthetic-journey")
           |> Ash.read(scope: scope) do
        {:ok, assignments} ->
          Enum.filter(assignments, fn assignment ->
            params = assignment.params || %{}
            params["web_property_id"] == web_property_id
          end)

        _ ->
          []
      end
    else
      []
    end
  end

  defp valid_uuid?(id) when is_binary(id) do
    match?({:ok, _}, Ecto.UUID.cast(id))
  end

  defp valid_uuid?(_), do: false

  defp edit_form_for(%WebProperty{} = wp) do
    to_form(
      %{
        "name" => wp.name,
        "canonical_origin" => wp.canonical_origin,
        "environment" => to_string(wp.environment),
        "allowed_origins" => Enum.join(wp.allowed_origins || [], "\n"),
        "allowed_query_keys" => Enum.join(wp.allowed_query_keys || [], ", "),
        "trace_propagate_origins" => Enum.join(wp.trace_propagate_origins || [], "\n"),
        "rum_enabled" => to_string(wp.rum_enabled),
        "rum_sample_rate" => to_string(wp.rum_sample_rate),
        "anonymize_client_ip" => to_string(wp.anonymize_client_ip)
      },
      as: :web_property
    )
  end

  defp default_binding_form do
    to_form(
      %{
        "binding_kind" => "origin_device",
        "device_uid" => "",
        "otel_service_name" => "",
        "cluster_id" => "",
        "namespace" => "",
        "resource_kind" => "HTTPRoute",
        "resource_name" => ""
      },
      as: :binding
    )
  end

  defp parse_update_attrs(params) do
    %{
      name: params |> Map.get("name", "") |> String.trim(),
      canonical_origin: params |> Map.get("canonical_origin", "") |> String.trim(),
      environment: parse_environment(Map.get(params, "environment")),
      allowed_origins: split_csv_lines(Map.get(params, "allowed_origins", "")),
      allowed_query_keys: split_csv_lines(Map.get(params, "allowed_query_keys", "")),
      trace_propagate_origins: split_csv_lines(Map.get(params, "trace_propagate_origins", "")),
      rum_enabled: parse_bool(Map.get(params, "rum_enabled"), true),
      rum_sample_rate: parse_float(Map.get(params, "rum_sample_rate"), 1.0),
      anonymize_client_ip: parse_bool(Map.get(params, "anonymize_client_ip"), true)
    }
  end

  defp build_binding_attrs(web_property_id, params) do
    kind =
      case Map.get(params, "binding_kind") do
        "k8s_public_endpoint" -> :k8s_public_endpoint
        "otel_service" -> :otel_service
        _ -> :origin_device
      end

    base = %{
      web_property_id: web_property_id,
      binding_kind: kind,
      source: :manual
    }

    case kind do
      :origin_device ->
        Map.put(base, :device_uid, trim_or_nil(Map.get(params, "device_uid")))

      :otel_service ->
        Map.put(base, :otel_service_name, trim_or_nil(Map.get(params, "otel_service_name")))

      :k8s_public_endpoint ->
        Map.merge(base, %{
          cluster_id: trim_or_nil(Map.get(params, "cluster_id")),
          namespace: String.trim(Map.get(params, "namespace") || ""),
          resource_kind: trim_or_nil(Map.get(params, "resource_kind")),
          resource_name: trim_or_nil(Map.get(params, "resource_name"))
        })
    end
  end

  defp parse_environment("staging"), do: :staging
  defp parse_environment("development"), do: :development
  defp parse_environment("internal"), do: :internal
  defp parse_environment(_), do: :production

  defp parse_bool("false", _default), do: false
  defp parse_bool("0", _default), do: false
  defp parse_bool(false, _default), do: false
  defp parse_bool("true", _default), do: true
  defp parse_bool("1", _default), do: true
  defp parse_bool(true, _default), do: true
  defp parse_bool(_, default), do: default

  defp parse_float(nil, default), do: default

  defp parse_float(raw, default) when is_binary(raw) do
    trimmed = String.trim(raw)

    if trimmed == "" do
      default
    else
      case Float.parse(trimmed) do
        {val, ""} -> val
        _ -> trimmed
      end
    end
  end

  defp parse_float(val, _default) when is_float(val), do: val
  defp parse_float(val, _default) when is_integer(val), do: val / 1
  defp parse_float(other, _default), do: other

  defp split_csv_lines(raw) when is_binary(raw) do
    raw
    |> String.split(~r/[\n,]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp split_csv_lines(_), do: []

  defp trim_or_nil(nil), do: nil

  defp trim_or_nil(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp format_ash_error(error) do
    Exception.message(error)
  rescue
    _ -> inspect(error)
  end

  @impl true
  def render(assigns) do
    timezone = user_timezone(assigns[:current_scope])
    assigns = assign(assigns, :timezone, timezone)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-6xl p-6 space-y-6">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <div class="flex items-center gap-2">
              <h1 class="text-2xl font-semibold text-sr-ink">
                {(@web_property && @web_property.name) || "Website Details"}
              </h1>
              <.ui_badge :if={@web_property} variant="primary" size="sm">
                {@web_property.environment}
              </.ui_badge>
            </div>
            <p :if={@web_property} class="mt-1 font-mono text-xs text-sr-muted">
              {@web_property.canonical_origin} · {@web_property.id}
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <.ui_button navigate={~p"/websites"} variant="ghost" size="sm">
              Back to Websites
            </.ui_button>
            <.ui_button
              id="open-web-rum-dashboard-button"
              navigate={~p"/dashboards/web-rum"}
              variant="outline"
              size="sm"
            >
              Web RUM Dashboard
            </.ui_button>
            <.ui_button
              :if={@web_property && @can_manage}
              id="edit-website-button"
              variant="outline"
              size="sm"
              phx-click="toggle_edit"
            >
              {if(@editing?, do: "Cancel Edit", else: "Edit")}
            </.ui_button>
            <.ui_button
              :if={@web_property && @can_manage}
              id="delete-website-button"
              variant="danger"
              size="sm"
              phx-click="delete_web_property"
              data-confirm="Delete this web property and its bindings?"
            >
              Delete
            </.ui_button>
          </div>
        </div>

        <div
          :if={@error}
          id="website-not-found"
          class="rounded-sr-surface border border-red-500/30 bg-red-500/5 p-6 text-center text-sm text-red-700 dark:text-red-300"
        >
          {@error}
        </div>

        <div :if={@web_property} class="space-y-6">
          <.ui_panel :if={@editing?} id="edit-website-panel">
            <:header>
              <span class="text-sm font-semibold text-sr-ink">Edit Web Property</span>
            </:header>

            <div
              :if={@form_error}
              id="edit-website-error"
              class="mb-3 rounded-sr-control border border-red-500/40 bg-red-500/10 p-3 text-xs text-red-700 dark:text-red-300"
            >
              {@form_error}
            </div>

            <.form
              for={@edit_form}
              id="edit-website-form"
              phx-submit="save_web_property"
              class="space-y-3"
            >
              <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
                <.input field={@edit_form[:name]} label="Name" required />
                <.input field={@edit_form[:canonical_origin]} label="Canonical Origin" required />
                <.input
                  field={@edit_form[:environment]}
                  type="select"
                  label="Environment"
                  options={[
                    {"Production", "production"},
                    {"Staging", "staging"},
                    {"Development", "development"},
                    {"Internal", "internal"}
                  ]}
                />
                <.input
                  field={@edit_form[:rum_sample_rate]}
                  type="number"
                  step="0.05"
                  min="0"
                  max="1"
                  label="RUM Sample Rate"
                />
              </div>

              <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
                <.input
                  field={@edit_form[:allowed_origins]}
                  type="textarea"
                  label="Allowed CORS Origins"
                />
                <.input
                  field={@edit_form[:allowed_query_keys]}
                  type="textarea"
                  label="Allowed Query Keys"
                />
                <.input
                  field={@edit_form[:trace_propagate_origins]}
                  type="textarea"
                  label="Trace Propagate Origins"
                />
              </div>

              <div class="flex flex-wrap gap-6">
                <.input field={@edit_form[:rum_enabled]} type="checkbox" label="RUM Enabled" />
                <.input
                  field={@edit_form[:anonymize_client_ip]}
                  type="checkbox"
                  label="Anonymize Client IP"
                />
              </div>

              <div class="flex justify-end gap-2 pt-2">
                <.ui_button id="save-website-button" type="submit" variant="primary" size="sm">
                  Save Changes
                </.ui_button>
              </div>
            </.form>
          </.ui_panel>

          <%!-- Posture & Policy Summary --%>
          <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <.ui_panel id="website-posture-panel">
              <:header>
                <span class="text-sm font-semibold text-sr-ink">Edge & TLS Posture</span>
              </:header>
              <dl class="grid grid-cols-2 gap-4 text-sm">
                <div>
                  <dt class="text-xs uppercase tracking-wider text-sr-muted">Edge Provider</dt>
                  <dd class="mt-1 font-medium text-sr-ink">{@web_property.edge_provider || "—"}</dd>
                </div>
                <div>
                  <dt class="text-xs uppercase tracking-wider text-sr-muted">TLS Issuer</dt>
                  <dd class="mt-1 text-sr-ink">{@web_property.tls_issuer || "—"}</dd>
                </div>
                <div>
                  <dt class="text-xs uppercase tracking-wider text-sr-muted">TLS Expires</dt>
                  <dd class="mt-1 font-mono text-xs text-sr-ink">
                    <.user_time
                      id={"wp-tls-not-after-#{@web_property.id}"}
                      value={@web_property.tls_not_after}
                      timezone={@timezone}
                      style={:full}
                    />
                  </dd>
                </div>
                <div>
                  <dt class="text-xs uppercase tracking-wider text-sr-muted">Posture Checked</dt>
                  <dd class="mt-1 font-mono text-xs text-sr-ink">
                    <.user_time
                      id={"wp-posture-checked-#{@web_property.id}"}
                      value={@web_property.last_posture_checked_at}
                      timezone={@timezone}
                      style={:compact}
                    />
                  </dd>
                </div>
                <div class="col-span-2">
                  <dt class="text-xs uppercase tracking-wider text-sr-muted">Observed VIPs</dt>
                  <dd class="mt-1 font-mono text-xs text-sr-ink">
                    {if(@web_property.observed_vips == [],
                      do: "—",
                      else: Enum.join(@web_property.observed_vips, ", ")
                    )}
                  </dd>
                </div>
                <div class="col-span-2">
                  <dt class="text-xs uppercase tracking-wider text-sr-muted">Observed ASNs</dt>
                  <dd class="mt-1 font-mono text-xs text-sr-ink">
                    {if(@web_property.observed_asns == [],
                      do: "—",
                      else: Enum.map_join(@web_property.observed_asns, ", ", &"AS#{&1}")
                    )}
                  </dd>
                </div>
              </dl>
            </.ui_panel>

            <.ui_panel id="website-rum-panel">
              <:header>
                <span class="text-sm font-semibold text-sr-ink">Boomerang RUM Configuration</span>
                <.ui_badge
                  variant={if(@web_property.rum_enabled, do: "success", else: "ghost")}
                  size="xs"
                >
                  {if(@web_property.rum_enabled, do: "RUM Enabled", else: "RUM Disabled")}
                </.ui_badge>
              </:header>

              <div class="space-y-4 text-sm">
                <div>
                  <div class="text-xs uppercase tracking-wider text-sr-muted">RUM Site Key</div>
                  <div class="mt-1 flex flex-wrap items-center gap-2">
                    <code
                      id="rum-site-key-value"
                      class="rounded-sr-control border border-sr-line bg-sr-subtle px-2.5 py-1 font-mono text-xs text-sr-ink"
                    >
                      {@web_property.rum_site_key}
                    </code>
                    <.ui_button
                      id="copy-rum-site-key-button"
                      variant="ghost"
                      size="xs"
                      phx-click="copy_value"
                      phx-value-value={@web_property.rum_site_key}
                    >
                      Copy
                    </.ui_button>
                    <.ui_button
                      :if={@can_manage}
                      id="rotate-rum-site-key-button"
                      variant="warning"
                      size="xs"
                      phx-click="rotate_rum_site_key"
                      data-confirm="Rotate RUM site key? Beacons using the current key will be rejected immediately."
                    >
                      Rotate Key
                    </.ui_button>
                  </div>
                </div>

                <dl class="grid grid-cols-2 gap-4">
                  <div>
                    <dt class="text-xs uppercase tracking-wider text-sr-muted">Sample Rate</dt>
                    <dd class="mt-1 font-mono text-xs text-sr-ink">
                      {Float.round(@web_property.rum_sample_rate * 100.0, 1)}%
                    </dd>
                  </div>
                  <div>
                    <dt class="text-xs uppercase tracking-wider text-sr-muted">
                      Anonymize Client IP
                    </dt>
                    <dd class="mt-1 text-xs text-sr-ink">
                      {if(@web_property.anonymize_client_ip,
                        do: "Enabled (/24 IPv4, /48 IPv6)",
                        else: "Disabled"
                      )}
                    </dd>
                  </div>
                  <div class="col-span-2">
                    <dt class="text-xs uppercase tracking-wider text-sr-muted">Allowed Origins</dt>
                    <dd class="mt-1 font-mono text-xs text-sr-ink">
                      {if(@web_property.allowed_origins == [],
                        do: @web_property.canonical_origin,
                        else: Enum.join(@web_property.allowed_origins, ", ")
                      )}
                    </dd>
                  </div>
                  <div class="col-span-2">
                    <dt class="text-xs uppercase tracking-wider text-sr-muted">
                      Trace Propagate Origins
                    </dt>
                    <dd class="mt-1 font-mono text-xs text-sr-ink">
                      {if(@web_property.trace_propagate_origins == [],
                        do: "Same-origin only",
                        else: Enum.join(@web_property.trace_propagate_origins, ", ")
                      )}
                    </dd>
                  </div>
                </dl>
              </div>
            </.ui_panel>
          </div>

          <.ui_panel id="website-rum-snippet-panel">
            <:header>
              <span class="text-sm font-semibold text-sr-ink">RUM Onboarding Snippets</span>
              <div class="flex flex-wrap items-center gap-2">
                <.ui_button
                  id="copy-rum-snippet-button"
                  variant="ghost"
                  size="xs"
                  phx-click="copy_value"
                  phx-value-value={rum_snippet_text(@web_property)}
                >
                  Copy Snippet
                </.ui_button>
                <.ui_button
                  id="copy-rum-mpulse-snippet-button"
                  variant="ghost"
                  size="xs"
                  phx-click="copy_value"
                  phx-value-value={rum_mpulse_tee_snippet_text(@web_property)}
                >
                  Copy mPulse Tee
                </.ui_button>
              </div>
            </:header>
            <div class="space-y-4">
              <div class="space-y-2">
                <p class="text-xs text-sr-muted">
                  Embed the first-party ServiceRadar Boomerang RUM bundle with optional W3C traceparent propagation.
                </p>
                <pre class="overflow-x-auto rounded-sr-control border border-sr-line bg-sr-subtle p-3 font-mono text-xs text-sr-ink"><code id="rum-boomerang-snippet" phx-no-curly-interpolation><%= rum_snippet_text(@web_property) %></code></pre>
              </div>
              <div class="space-y-2 border-t border-sr-line pt-3">
                <p class="text-xs text-sr-muted">
                  Or tee beacons from an existing Akamai mPulse Boomerang tag without changing your CDN tag deployment.
                </p>
                <pre class="overflow-x-auto rounded-sr-control border border-sr-line bg-sr-subtle p-3 font-mono text-xs text-sr-ink"><code id="rum-mpulse-tee-snippet" phx-no-curly-interpolation><%= rum_mpulse_tee_snippet_text(@web_property) %></code></pre>
              </div>
            </div>
          </.ui_panel>

          <%!-- Infrastructure Bindings --%>
          <.ui_panel id="website-bindings-panel">
            <:header>
              <div>
                <span class="text-sm font-semibold text-sr-ink">
                  Infrastructure Bindings ({@bindings_count})
                </span>
                <p class="text-xs text-sr-muted">
                  Kubernetes gateways/routes, direct origin devices, and OpenTelemetry services linked to this web property.
                </p>
              </div>
            </:header>

            <div class="space-y-4">
              <div class="sr-ui-table-shell overflow-x-auto">
                <table
                  id="bindings-table"
                  class={ui_table_class(size: "sm", zebra: true, class: "w-full")}
                >
                  <thead>
                    <tr>
                      <th class="text-xs font-semibold text-sr-muted bg-sr-subtle/60">Kind</th>
                      <th class="text-xs font-semibold text-sr-muted bg-sr-subtle/60">Source</th>
                      <th class="text-xs font-semibold text-sr-muted bg-sr-subtle/60">Target</th>
                      <th class="text-xs font-semibold text-sr-muted bg-sr-subtle/60">Observed</th>
                      <th class="text-xs font-semibold text-sr-muted bg-sr-subtle/60"></th>
                    </tr>
                  </thead>
                  <tbody id="bindings-rows" phx-update="stream">
                    <tr id="bindings-empty-row" class="hidden only:table-row">
                      <td colspan="5" class="py-6 text-center text-xs text-sr-muted">
                        No infrastructure bindings yet.
                      </td>
                    </tr>
                    <tr :for={{dom_id, binding} <- @streams.bindings} id={dom_id}>
                      <td class="whitespace-nowrap text-xs">
                        <.ui_badge variant="info" size="xs">{binding.binding_kind}</.ui_badge>
                      </td>
                      <td class="whitespace-nowrap text-xs text-sr-muted">{binding.source}</td>
                      <td class="whitespace-nowrap font-mono text-xs text-sr-ink">
                        <%= case binding.binding_kind do %>
                          <% :origin_device -> %>
                            <.link
                              navigate={~p"/devices/#{binding.device_uid}"}
                              class="text-sr-brand hover:underline"
                            >
                              {binding.device_uid}
                            </.link>
                          <% :otel_service -> %>
                            {binding.otel_service_name}
                          <% :k8s_public_endpoint -> %>
                            {"#{binding.cluster_id}/#{binding.namespace}/#{binding.resource_kind}/#{binding.resource_name}"}
                        <% end %>
                      </td>
                      <td class="whitespace-nowrap font-mono text-xs text-sr-muted">
                        <.user_time
                          id={"binding-obs-#{binding.id}"}
                          value={binding.last_observed_at || binding.updated_at}
                          timezone={@timezone}
                          style={:compact}
                        />
                      </td>
                      <td class="whitespace-nowrap text-right">
                        <.ui_button
                          :if={@can_manage}
                          id={"delete-binding-#{binding.id}"}
                          variant="ghost"
                          size="xs"
                          phx-click="delete_binding"
                          phx-value-id={binding.id}
                        >
                          Remove
                        </.ui_button>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>

              <div :if={@can_manage} class="border-t border-sr-line pt-4">
                <div
                  :if={@binding_error}
                  id="binding-form-error"
                  class="mb-2 rounded-sr-control border border-red-500/40 bg-red-500/10 p-2 text-xs text-red-700 dark:text-red-300"
                >
                  {@binding_error}
                </div>
                <.form
                  for={@binding_form}
                  id="add-binding-form"
                  phx-submit="create_binding"
                  class="grid grid-cols-1 gap-3 md:grid-cols-4 items-end"
                >
                  <.input
                    field={@binding_form[:binding_kind]}
                    type="select"
                    label="Binding Kind"
                    options={[
                      {"Origin Device", "origin_device"},
                      {"OTel Service", "otel_service"},
                      {"K8s Public Endpoint", "k8s_public_endpoint"}
                    ]}
                  />
                  <.input
                    field={@binding_form[:device_uid]}
                    label="Device UID"
                    placeholder="sr:..."
                  />
                  <.input
                    field={@binding_form[:otel_service_name]}
                    label="OTel Service Name"
                    placeholder="checkout-frontend"
                  />
                  <div class="flex gap-2">
                    <.ui_button id="submit-add-binding" type="submit" variant="neutral" size="sm">
                      Add Binding
                    </.ui_button>
                  </div>
                  <.input
                    field={@binding_form[:cluster_id]}
                    label="K8s Cluster ID"
                    placeholder="demo-cluster"
                  />
                  <.input
                    field={@binding_form[:namespace]}
                    label="K8s Namespace"
                    placeholder="web"
                  />
                  <.input
                    field={@binding_form[:resource_kind]}
                    label="K8s Resource Kind"
                    placeholder="HTTPRoute"
                  />
                  <.input
                    field={@binding_form[:resource_name]}
                    label="K8s Resource Name"
                    placeholder="shop-route"
                  />
                </.form>
              </div>
            </div>
          </.ui_panel>

          <%!-- Linked ServiceChecks & Synthetic Journeys --%>
          <.ui_panel id="website-checks-panel">
            <:header>
              <div>
                <span class="text-sm font-semibold text-sr-ink">
                  Linked Service Checks ({@service_checks_count}) &amp; Synthetic Journeys ({length(
                    @synthetic_assignments
                  )})
                </span>
                <p class="text-xs text-sr-muted">
                  Active monitoring checks and http-synthetic-journey Wasm plugins attached to this web property.
                </p>
              </div>
            </:header>

            <div class="space-y-4">
              <div class="sr-ui-table-shell overflow-x-auto">
                <table
                  id="service-checks-table"
                  class={ui_table_class(size: "sm", zebra: true, class: "w-full")}
                >
                  <thead>
                    <tr>
                      <th class="text-xs font-semibold text-sr-muted bg-sr-subtle/60">Name</th>
                      <th class="text-xs font-semibold text-sr-muted bg-sr-subtle/60">Type</th>
                      <th class="text-xs font-semibold text-sr-muted bg-sr-subtle/60">Target</th>
                      <th class="text-xs font-semibold text-sr-muted bg-sr-subtle/60">Result</th>
                      <th class="text-xs font-semibold text-sr-muted bg-sr-subtle/60">
                        Last Checked
                      </th>
                    </tr>
                  </thead>
                  <tbody id="service-checks-rows" phx-update="stream">
                    <tr id="service-checks-empty-row" class="hidden only:table-row">
                      <td colspan="5" class="py-6 text-center text-xs text-sr-muted">
                        No service checks linked to this web property.
                      </td>
                    </tr>
                    <tr :for={{dom_id, check} <- @streams.service_checks} id={dom_id}>
                      <td class="whitespace-nowrap text-xs font-medium text-sr-ink">{check.name}</td>
                      <td class="whitespace-nowrap text-xs text-sr-muted">{check.check_type}</td>
                      <td class="whitespace-nowrap font-mono text-xs text-sr-ink">{check.target}</td>
                      <td class="whitespace-nowrap text-xs">
                        <.ui_badge variant={badge_variant_for(check.last_result)} size="xs">
                          {check.last_result || "pending"}
                        </.ui_badge>
                      </td>
                      <td class="whitespace-nowrap font-mono text-xs text-sr-muted">
                        <.user_time
                          id={"check-last-#{check.id}"}
                          value={check.last_check_at}
                          timezone={@timezone}
                          style={:compact}
                        />
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>

              <div :if={@synthetic_assignments != []} class="border-t border-sr-line pt-3 space-y-2">
                <div class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
                  Synthetic Journey Wasm Assignments
                </div>
                <div
                  :for={assignment <- @synthetic_assignments}
                  id={"synthetic-assignment-#{assignment.id}"}
                  class="flex items-center justify-between rounded-sr-control border border-sr-line bg-sr-subtle/40 px-3 py-2 text-xs"
                >
                  <span class="font-mono text-sr-ink">
                    {assignment.plugin_id} · agent {assignment.agent_uid}
                  </span>
                  <.ui_badge variant={if(assignment.enabled, do: "success", else: "ghost")} size="xs">
                    {if(assignment.enabled, do: "Enabled", else: "Disabled")}
                  </.ui_badge>
                </div>
              </div>
            </div>
          </.ui_panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp rum_snippet_text(%WebProperty{} = wp) do
    String.trim("""
    <script src="/assets/rum/boomerang-sr.min.js" async crossorigin="anonymous"></script>
    <script>
      window.BOOMR_config = window.BOOMR_config || {};
      window.BOOMR_config.ServiceRadar = {
        siteKey: #{Jason.encode!(wp.rum_site_key || "")},
        beaconUrl: "/rum/v1/beacon",
        sampleRate: #{wp.rum_sample_rate},
        tracePropagateOrigins: #{Jason.encode!(wp.trace_propagate_origins || [])}
      };
    </script>
    """)
  end

  defp rum_mpulse_tee_snippet_text(%WebProperty{} = wp) do
    site_key = wp.rum_site_key || ""
    encoded_key = URI.encode_www_form(site_key)

    String.trim("""
    <script>
      window.BOOMR && BOOMR.subscribe("beacon", function(vars) {
        if (!vars || vars["sr.key"]) return;
        var p = new URLSearchParams({ "sr.key": #{Jason.encode!(site_key)}, u: vars.u || location.href, "c.lcp": vars["pt.lcp"] || vars["c.lcp"] || "", "c.inp": vars["et.inp"] || vars["c.inp"] || "", "c.cls": vars["c.cls"] || "", "c.fcp": vars["pt.fcp"] || vars["c.fcp"] || "", "c.ttfb": vars.t_resp || vars["c.ttfb"] || "", t_done: vars.t_done || "", servertiming: vars.servertiming || "" });
        navigator.sendBeacon("/rum/v1/beacon?key=#{encoded_key}", p);
      });
    </script>
    """)
  end

  defp user_timezone(%{user: %{timezone: timezone}}) when is_binary(timezone) and timezone != "", do: timezone

  defp user_timezone(_), do: "Etc/UTC"
end
