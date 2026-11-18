defmodule ServiceRadarWebNGWeb.WebPropertyLive.Index do
  @moduledoc """
  SRQL list and creation LiveView for L7 Web Properties (`in:websites` -> `platform.web_properties`).
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Inventory.WebProperty
  alias ServiceRadar.Inventory.WebPropertyPubSub
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @page_path "/websites"
  @default_limit 50
  @max_limit 200
  @default_query "in:websites sort:name:asc limit:50"

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
     |> assign(:page_title, "Websites")
     |> assign(:can_view, can_view)
     |> assign(:can_manage, can_manage)
     |> assign(:limit, @default_limit)
     |> assign(:websites_count, 0)
     |> assign(:show_create_modal, false)
     |> assign(:form_error, nil)
     |> assign(:create_form, default_create_form())
     |> stream_configure(:websites, dom_id: &website_dom_id/1)
     |> stream(:websites, [])
     |> SRQLPage.init("websites", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    if socket.assigns.can_view do
      params = ensure_default_query(params)

      socket =
        socket
        |> assign(:last_params, params)
        |> assign(:last_uri, uri)
        |> SRQLPage.sync_from_params(params, uri,
          default_limit: @default_limit,
          max_limit: @max_limit
        )

      if connected?(socket) do
        {:noreply, load_websites(socket, params)}
      else
        request = SRQLPage.list_request(socket, params, :websites, list_opts())

        {:noreply,
         socket
         |> SRQLPage.apply_list_result(request, {[], nil, nil, %{}}, loading: true)
         |> assign(:websites_count, 0)
         |> stream(:websites, [], reset: true)}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "You do not have permission to view websites.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: @page_path)}
  end

  def handle_event("srql_reset", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_reset", params, fallback_path: @page_path)}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "websites")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: @page_path)}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "websites")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "websites")}
  end

  def handle_event("srql_paginate", params, socket) do
    next_socket =
      SRQLPage.handle_event(socket, "srql_paginate", params,
        list_assign_key: :websites,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    results = Map.get(next_socket.assigns, :websites, [])

    {:noreply,
     next_socket
     |> assign(:websites_count, length(results))
     |> stream(:websites, results, reset: true)}
  end

  def handle_event("open_create_modal", _params, socket) do
    if socket.assigns.can_manage do
      {:noreply,
       socket
       |> assign(:show_create_modal, true)
       |> assign(:form_error, nil)
       |> assign(:create_form, default_create_form())}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage websites.")}
    end
  end

  def handle_event("close_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_modal, false)
     |> assign(:form_error, nil)}
  end

  def handle_event("validate_web_property", %{"web_property" => params}, socket) do
    {:noreply, assign(socket, :create_form, to_form(params, as: :web_property))}
  end

  def handle_event("create_web_property", %{"web_property" => params}, socket) do
    scope = socket.assigns[:current_scope]

    if RBAC.can?(scope, "settings.networks.manage") do
      attrs = parse_web_property_attrs(params)

      case WebProperty
           |> Ash.Changeset.for_create(:create, attrs)
           |> Ash.create(scope: scope) do
        {:ok, wp} ->
          {:noreply,
           socket
           |> assign(:show_create_modal, false)
           |> put_flash(:info, "Web property created.")
           |> push_navigate(to: ~p"/websites/#{wp.id}")}

        {:error, error} ->
          {:noreply,
           socket
           |> assign(:form_error, format_ash_error(error))
           |> assign(:create_form, to_form(params, as: :web_property))}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to create websites.")}
    end
  end

  @impl true
  def handle_info({event, _id, _record}, socket) when event in [:web_property_created, :web_property_updated] do
    {:noreply, refresh_if_connected(socket)}
  end

  def handle_info({:web_property_deleted, _id}, socket) do
    {:noreply, refresh_if_connected(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh_if_connected(socket) do
    if connected?(socket) and socket.assigns.can_view do
      params = Map.get(socket.assigns, :last_params, %{"q" => @default_query})
      load_websites(socket, params)
    else
      socket
    end
  end

  defp load_websites(socket, params) do
    request = SRQLPage.list_request(socket, params, :websites, list_opts())
    {results, error, viz, pagination} = SRQLPage.fetch_list(request)

    socket
    |> SRQLPage.apply_list_result(request, {results, error, viz, pagination}, loading: false)
    |> assign(:websites_count, length(results))
    |> stream(:websites, results, reset: true)
  end

  defp list_opts do
    [default_limit: @default_limit, max_limit: @max_limit]
  end

  defp ensure_default_query(params) do
    case Map.get(params, "q") do
      q when is_binary(q) ->
        if String.trim(q) == "", do: Map.put(params, "q", @default_query), else: params

      _ ->
        Map.put(params, "q", @default_query)
    end
  end

  defp default_create_form do
    to_form(
      %{
        "name" => "",
        "canonical_origin" => "",
        "environment" => "production",
        "allowed_origins" => "",
        "allowed_query_keys" => "",
        "trace_propagate_origins" => "",
        "rum_enabled" => "true",
        "rum_sample_rate" => "1.0",
        "anonymize_client_ip" => "true"
      },
      as: :web_property
    )
  end

  defp parse_web_property_attrs(params) do
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

  defp parse_float(raw, default) when is_binary(raw) do
    case Float.parse(String.trim(raw)) do
      {val, ""} -> val
      _ -> default
    end
  end

  defp parse_float(val, _default) when is_float(val), do: val
  defp parse_float(val, _default) when is_integer(val), do: val / 1
  defp parse_float(_, default), do: default

  defp split_csv_lines(raw) when is_binary(raw) do
    raw
    |> String.split(~r/[\n,]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp split_csv_lines(_), do: []

  defp website_dom_id(%{"id" => id}), do: "website-#{id}"
  defp website_dom_id(%{id: id}), do: "website-#{id}"
  defp website_dom_id(_), do: "website-#{System.unique_integer([:positive])}"

  defp format_ash_error(error) do
    Exception.message(error)
  rescue
    _ -> inspect(error)
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    timezone = user_timezone(assigns[:current_scope])

    assigns =
      assigns
      |> assign(:pagination, pagination)
      |> assign(:timezone, timezone)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6 space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-sr-ink">Websites</h1>
            <p class="mt-1 text-sm text-sr-muted">
              L7 Web Property inventory, Boomerang RUM policies, CDN/TLS posture, and origin bindings.
            </p>
          </div>
          <.ui_button
            :if={@can_manage}
            id="new-website-button"
            variant="primary"
            size="sm"
            phx-click="open_create_modal"
          >
            <.icon name="hero-plus" class="size-4" /> Add Web Property
          </.ui_button>
        </div>

        <.ui_panel id="websites-panel">
          <div class="sr-ui-table-shell overflow-x-auto">
            <table
              id="websites-table"
              class={ui_table_class(size: "sm", zebra: true, class: "w-full")}
            >
              <thead>
                <tr>
                  <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
                    Name
                  </th>
                  <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
                    Canonical Origin
                  </th>
                  <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
                    Environment
                  </th>
                  <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
                    Edge Provider
                  </th>
                  <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
                    RUM
                  </th>
                  <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
                    Bindings
                  </th>
                  <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
                    TLS Expires
                  </th>
                  <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
                    Updated
                  </th>
                </tr>
              </thead>
              <tbody id="websites-rows" phx-update="stream">
                <tr id="websites-empty-row" class="hidden only:table-row">
                  <td colspan="8" class="py-8 text-center text-sm text-sr-muted">
                    No websites matched.
                  </td>
                </tr>
                <tr
                  :for={{dom_id, site} <- @streams.websites}
                  id={dom_id}
                  class="hover:bg-sr-subtle/40 transition-colors"
                >
                  <td class="whitespace-nowrap text-sm font-medium text-sr-ink">
                    <.link navigate={~p"/websites/#{site["id"]}"} class="hover:underline">
                      {site["name"] || "—"}
                    </.link>
                  </td>
                  <td class="whitespace-nowrap font-mono text-xs text-sr-ink">
                    {site["canonical_origin"] || "—"}
                  </td>
                  <td class="whitespace-nowrap text-xs">
                    <.ui_badge variant={env_variant(site["environment"])} size="xs">
                      {site["environment"] || "production"}
                    </.ui_badge>
                  </td>
                  <td class="whitespace-nowrap text-xs text-sr-muted">
                    {site["edge_provider"] || "—"}
                  </td>
                  <td class="whitespace-nowrap text-xs">
                    <.ui_badge
                      variant={if(site["rum_enabled"], do: "success", else: "ghost")}
                      size="xs"
                    >
                      {if(site["rum_enabled"], do: "Enabled", else: "Disabled")}
                    </.ui_badge>
                  </td>
                  <td class="whitespace-nowrap font-mono text-xs text-sr-muted">
                    {site["binding_count"] || 0}
                  </td>
                  <td class="whitespace-nowrap font-mono text-xs text-sr-muted">
                    <.user_time
                      id={"site-tls-#{site["id"]}"}
                      value={site["tls_not_after"]}
                      timezone={@timezone}
                      style={:date}
                    />
                  </td>
                  <td class="whitespace-nowrap font-mono text-xs text-sr-muted">
                    <.user_time
                      id={"site-updated-#{site["id"]}"}
                      value={site["updated_at"]}
                      timezone={@timezone}
                      style={:compact}
                    />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="mt-4 pt-4 border-t border-sr-line">
            <.ui_pagination
              prev_cursor={Map.get(@pagination, "prev_cursor")}
              next_cursor={Map.get(@pagination, "next_cursor")}
              limit={@limit}
              current_page={Map.get(assigns, :pagination_page, 1)}
              result_count={@websites_count}
            />
          </div>
        </.ui_panel>
      </div>

      <div
        :if={@show_create_modal}
        id="create-website-modal"
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
        role="dialog"
        aria-modal="true"
        aria-labelledby="create-website-title"
      >
        <div class="w-full max-w-lg rounded-sr-surface border border-sr-line bg-sr-surface p-6 shadow-sr-raised">
          <div class="flex items-center justify-between border-b border-sr-line pb-3">
            <h2 id="create-website-title" class="text-lg font-semibold text-sr-ink">
              Add Web Property
            </h2>
            <.ui_icon_button
              variant="ghost"
              size="xs"
              phx-click="close_create_modal"
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </.ui_icon_button>
          </div>

          <div
            :if={@form_error}
            id="create-website-error"
            class="mt-3 rounded-sr-control border border-red-500/40 bg-red-500/10 p-3 text-xs text-red-700 dark:text-red-300"
          >
            {@form_error}
          </div>

          <.form
            for={@create_form}
            id="create-website-form"
            phx-change="validate_web_property"
            phx-submit="create_web_property"
            class="mt-4 space-y-3"
          >
            <.input
              field={@create_form[:name]}
              label="Name"
              placeholder="Example Storefront"
              required
            />
            <.input
              field={@create_form[:canonical_origin]}
              label="Canonical Origin"
              placeholder="https://shop.example.com"
              required
            />
            <.input
              field={@create_form[:environment]}
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
              field={@create_form[:allowed_origins]}
              label="Allowed CORS Origins (comma or newline separated)"
              placeholder="https://shop.example.com"
            />
            <.input
              field={@create_form[:allowed_query_keys]}
              label="Allowed Query Keys (non-PII)"
              placeholder="utm_source, page"
            />
            <.input
              field={@create_form[:trace_propagate_origins]}
              label="Trace Propagate Origins"
              placeholder="https://api.example.com"
            />
            <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
              <.input
                field={@create_form[:rum_sample_rate]}
                type="number"
                step="0.05"
                min="0"
                max="1"
                label="RUM Sample Rate"
              />
              <div class="flex items-end pb-2">
                <.input field={@create_form[:rum_enabled]} type="checkbox" label="RUM Enabled" />
              </div>
              <div class="flex items-end pb-2">
                <.input
                  field={@create_form[:anonymize_client_ip]}
                  type="checkbox"
                  label="Anonymize IP"
                />
              </div>
            </div>

            <div class="flex justify-end gap-2 pt-3 border-t border-sr-line">
              <.ui_button type="button" variant="ghost" phx-click="close_create_modal">
                Cancel
              </.ui_button>
              <.ui_button id="submit-create-website" type="submit" variant="primary">
                Create Web Property
              </.ui_button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp env_variant("production"), do: "primary"
  defp env_variant("staging"), do: "warning"
  defp env_variant("development"), do: "info"
  defp env_variant(_), do: "ghost"

  defp user_timezone(%{user: %{timezone: timezone}}) when is_binary(timezone) and timezone != "", do: timezone

  defp user_timezone(_), do: "Etc/UTC"
end
