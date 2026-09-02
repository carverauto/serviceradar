defmodule ServiceRadarWebNGWeb.PublicEndpointsLive.Index do
  @moduledoc """
  SRQL list page for Kubernetes public endpoint inventory
  (`in:public_endpoints` → `platform.public_endpoints_current`).
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @page_path "/inventory/public-endpoints"
  @default_limit 50
  @max_limit 200
  @default_query "in:public_endpoints sort:ip:asc limit:50"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Public Endpoints")
     |> assign(:endpoints, [])
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("public_endpoints", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    params =
      case Map.get(params, "q") do
        q when is_binary(q) ->
          if String.trim(q) == "", do: Map.put(params, "q", @default_query), else: params

        _ ->
          Map.put(params, "q", @default_query)
      end

    {:noreply,
     SRQLPage.load_list(socket, params, uri, :endpoints,
       default_limit: @default_limit,
       max_limit: @max_limit
     )}
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
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "public_endpoints")}
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
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "public_endpoints")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "public_endpoints")}
  end

  def handle_event("srql_paginate", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_paginate", params,
       list_assign_key: :endpoints,
       default_limit: @default_limit,
       max_limit: @max_limit
     )}
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    assigns = assign(assigns, :pagination, pagination)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6 space-y-4">
        <div>
          <h1 class="text-2xl font-semibold text-sr-fg">Public Endpoints</h1>
          <p class="mt-1 text-sm text-sr-muted">
            Cluster-plane ownership of LoadBalancer VIPs and Gateway API routes
            (not host-agent process attribution).
          </p>
        </div>

        <.ui_panel>
          <.endpoints_table id="public-endpoints" endpoints={@endpoints} />

          <div class="mt-4 pt-4 border-t border-sr-line">
            <.ui_pagination
              prev_cursor={Map.get(@pagination, "prev_cursor")}
              next_cursor={Map.get(@pagination, "next_cursor")}
              limit={@limit}
              current_page={Map.get(assigns, :pagination_page, 1)}
              result_count={length(@endpoints)}
            />
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :endpoints, :list, default: []

  defp endpoints_table(assigns) do
    ~H"""
    <div class="sr-ui-table-shell overflow-x-auto">
      <table id={@id} class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">IP</th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Port
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Proto
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Class
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Namespace
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Service
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Gateway
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Route
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Pool
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@endpoints == []}>
            <td colspan="9" class="text-sm text-sr-muted py-8 text-center">
              No public endpoints matched.
            </td>
          </tr>

          <%= for {ep, idx} <- Enum.with_index(@endpoints) do %>
            <tr id={"#{@id}-row-#{idx}"} class="hover:bg-sr-subtle/40 transition-colors">
              <td class="whitespace-nowrap text-xs font-mono">{field(ep, "ip")}</td>
              <td class="whitespace-nowrap text-xs font-mono">{field(ep, "port")}</td>
              <td class="whitespace-nowrap text-xs">{field(ep, "protocol")}</td>
              <td class="whitespace-nowrap text-xs">
                <.ui_badge variant={class_variant(field(ep, "exposure_class"))} size="xs">
                  {field(ep, "exposure_class")}
                </.ui_badge>
              </td>
              <td class="whitespace-nowrap text-xs">{field(ep, "namespace")}</td>
              <td class="whitespace-nowrap text-xs">{field(ep, "service_name")}</td>
              <td class="whitespace-nowrap text-xs">{field(ep, "gateway_name")}</td>
              <td class="whitespace-nowrap text-xs font-mono">
                {route_label(ep)}
              </td>
              <td class="whitespace-nowrap text-xs">{field(ep, "metallb_pool")}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  # Endpoint rows arrive with either string keys (decoded from the inventory snapshot) or
  # atom keys (loaded through Ecto), so both are tried.
  #
  # to_existing_atom, not to_atom: the atom table is never garbage collected, so to_atom on
  # anything that is not already an atom grows it permanently. Every caller here passes a
  # literal, so today that set is bounded and this is only a latent risk -- but it is also the
  # exact shape AGENTS.md forbids ("no String.to_atom/1 with user input"), and one caller
  # passing a user-supplied key later would turn it into a DoS. to_existing_atom cannot add
  # to the table at all, which removes the hazard rather than relying on callers.
  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, existing_atom(key)) || "—"
  end

  defp field(_, _), do: "—"

  # nil is a fine Map.get/2 key: it simply misses, which is the same outcome as an atom that
  # was never defined.
  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp route_label(ep) do
    kind = field(ep, "route_kind")
    name = field(ep, "route_name")

    cond do
      kind not in [nil, "", "—"] and name not in [nil, "", "—"] -> "#{kind}/#{name}"
      name not in [nil, "", "—"] -> name
      true -> "—"
    end
  end

  defp class_variant("LoadBalancer"), do: "info"
  defp class_variant("Gateway"), do: "success"
  defp class_variant("ExternalIP"), do: "warning"
  defp class_variant(_), do: "ghost"
end
