defmodule ServiceRadarWebNGWeb.AnsibleLive.CatalogIndex do
  @moduledoc """
  Browser for the Ansible playbook catalog.

  Shows both git-sourced and AWX-sourced `Playbook` rows side by side.
  Filterable by source type (all / git / awx), launchability
  (anything / launchable / unbound), and parse status. Operators use
  this surface to discover which playbooks exist before kicking off
  a run from `/devices` → Launch Playbook.

  Permission: `ansible.catalog.view`. Read-only -- launch flow lives
  on `/ansible/launch` (reached via the inventory list / device detail
  Launch Playbook button).
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNGWeb.Authorization,
    resource_module: ServiceRadar.Automation.Ansible.Playbook

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @page_limit 500
  @source_filters ~w(all git awx)
  @binding_filters ~w(all launchable unbound)

  @impl true
  def event_mapping do
    Map.merge(Permit.Phoenix.LiveView.default_event_mapping(), %{
      "filter_source" => :read,
      "filter_binding" => :read,
      "filter_search" => :read,
      "refresh" => :read
    })
  end

  @impl true
  def skip_preload, do: [:index, :read]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "ansible.catalog.view") do
      filters = %{source: "all", binding: "all", search: ""}

      socket =
        socket
        |> assign(:page_title, "Ansible playbook catalog")
        |> assign(:page_limit, @page_limit)
        |> assign(:filters, filters)
        |> assign(:source_filters, @source_filters)
        |> assign(:binding_filters, @binding_filters)
        |> assign(:playbook_count, 0)
        |> stream(:playbooks, [], reset: true)

      {:ok, if(connected?(socket), do: load_playbooks(socket, filters), else: socket)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to view the Ansible catalog.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("filter_source", %{"value" => value}, socket) when value in @source_filters do
    apply_filters(socket, %{socket.assigns.filters | source: value})
  end

  def handle_event("filter_binding", %{"value" => value}, socket) when value in @binding_filters do
    apply_filters(socket, %{socket.assigns.filters | binding: value})
  end

  def handle_event("filter_search", %{"value" => value}, socket) when is_binary(value) do
    apply_filters(socket, %{socket.assigns.filters | search: value})
  end

  def handle_event("refresh", _params, socket) do
    apply_filters(socket, socket.assigns.filters)
  end

  defp apply_filters(socket, filters) do
    {:noreply, load_playbooks(socket, filters)}
  end

  defp load_playbooks(socket, filters) do
    playbooks = list_playbooks(filters)

    socket
    |> assign(:filters, filters)
    |> assign(:playbook_count, length(playbooks))
    |> stream(:playbooks, playbooks, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path="/ansible/catalog"
      page_title={@page_title}
      shell={:operations}
    >
      <div class="mx-auto w-full max-w-7xl p-6 space-y-4">
        <header class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-semibold">Ansible playbook catalog</h1>
            <p id="ansible-catalog-count" class="text-sm text-sr-muted">
              {@playbook_count} playbook{if @playbook_count == 1, do: "", else: "s"} shown
              (capped at {@page_limit}).
            </p>
          </div>
          <.ui_button type="button" phx-click="refresh" size="sm" variant="ghost">
            Refresh
          </.ui_button>
        </header>

        <div class="flex flex-wrap items-end gap-3">
          <div>
            <p class="text-xs text-sr-muted mb-1">Source</p>
            <div class="flex flex-wrap gap-1">
              <.ui_button
                :for={src <- @source_filters}
                type="button"
                phx-click="filter_source"
                phx-value-value={src}
                size="xs"
                variant={if(src == @filters.source, do: "primary", else: "ghost")}
                active={src == @filters.source}
              >
                {src}
              </.ui_button>
            </div>
          </div>

          <div>
            <p class="text-xs text-sr-muted mb-1">Binding</p>
            <div class="flex flex-wrap gap-1">
              <.ui_button
                :for={state <- @binding_filters}
                type="button"
                phx-click="filter_binding"
                phx-value-value={state}
                size="xs"
                variant={if(state == @filters.binding, do: "primary", else: "ghost")}
                active={state == @filters.binding}
              >
                {state}
              </.ui_button>
            </div>
          </div>

          <form
            id="ansible-catalog-search"
            phx-change="filter_search"
            class="flex-1 min-w-[16rem] max-w-md"
          >
            <input
              type="text"
              name="value"
              value={@filters.search}
              placeholder="Filter by name / description / tag…"
              class={ui_field_class(size: "sm", class: "w-full")}
              phx-debounce="250"
            />
          </form>
        </div>

        <div
          :if={@playbook_count == 0}
          class="rounded-lg border border-dashed border-sr-line p-8 text-center text-sm text-sr-muted"
        >
          No playbooks match the current filters.
          <p class="mt-2">
            New AWX controllers and git repositories sync in the background;
            the catalog populates within the configured sync interval.
          </p>
        </div>

        <div
          :if={@playbook_count > 0}
          class="overflow-x-auto rounded-lg border border-sr-line bg-sr-surface"
        >
          <table class={ui_table_class(size: "sm", zebra: true)}>
            <thead>
              <tr>
                <th>Name</th>
                <th>Source</th>
                <th>Origin</th>
                <th>AWX template</th>
                <th>Tags</th>
                <th>Parse</th>
              </tr>
            </thead>
            <tbody id="ansible-catalog" phx-update="stream">
              <tr :for={{id, pb} <- @streams.playbooks} id={id}>
                <td>
                  <div class="font-medium">{pb.name}</div>
                  <div :if={pb.description} class="text-xs text-sr-muted">{pb.description}</div>
                  <div :if={pb.path} class="text-xs text-sr-muted font-mono mt-1">{pb.path}</div>
                </td>
                <td>
                  <.ui_badge size="sm" variant={source_badge_variant(pb.source_type)}>
                    {pb.source_type}
                  </.ui_badge>
                </td>
                <td>
                  <code class="text-xs">{shorten(pb.repository_id || pb.controller_id)}</code>
                </td>
                <td>
                  <.ui_badge :if={pb.awx_job_template_id} size="sm" variant="success">
                    {pb.awx_job_template_id}
                  </.ui_badge>
                  <.ui_badge :if={!pb.awx_job_template_id} size="sm" variant="warning">
                    unbound
                  </.ui_badge>
                </td>
                <td>
                  <div class="flex flex-wrap gap-1">
                    <.ui_badge :for={tag <- pb.tags || []} size="xs" variant="ghost">{tag}</.ui_badge>
                    <span :if={pb.tags == []} class="text-xs text-sr-muted">—</span>
                  </div>
                </td>
                <td>
                  <.ui_badge size="sm" variant={parse_badge_variant(pb.parse_status)}>
                    {pb.parse_status}
                  </.ui_badge>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  ## Helpers -------------------------------------------------------------------

  defp list_playbooks(filters) do
    query =
      Playbook
      |> apply_source_filter(filters.source)
      |> apply_binding_filter(filters.binding)
      |> apply_search_filter(filters.search)
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(@page_limit)

    case Ash.read(query, actor: actor()) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp apply_source_filter(query, "git"), do: Ash.Query.filter(query, source_type == :git)
  defp apply_source_filter(query, "awx"), do: Ash.Query.filter(query, source_type == :awx)
  defp apply_source_filter(query, _), do: query

  defp apply_binding_filter(query, "launchable"), do: Ash.Query.filter(query, not is_nil(awx_job_template_id))

  defp apply_binding_filter(query, "unbound"), do: Ash.Query.filter(query, is_nil(awx_job_template_id))

  defp apply_binding_filter(query, _), do: query

  defp apply_search_filter(query, ""), do: query

  defp apply_search_filter(query, term) when is_binary(term) do
    trimmed = String.trim(term)

    if trimmed == "" do
      query
    else
      pattern = "%" <> trimmed <> "%"
      Ash.Query.filter(query, ilike(name, ^pattern) or ilike(description, ^pattern))
    end
  end

  defp apply_search_filter(query, _), do: query

  defp actor, do: SystemActor.system(:ansible_catalog_index)

  defp source_badge_variant(:git), do: "info"
  defp source_badge_variant(:awx), do: "primary"
  defp source_badge_variant(_), do: "ghost"

  defp parse_badge_variant(:ok), do: "success"
  defp parse_badge_variant(:error), do: "error"
  defp parse_badge_variant(:pending), do: "ghost"
  defp parse_badge_variant(_), do: "ghost"

  defp shorten(nil), do: "—"
  defp shorten(s) when is_binary(s) and byte_size(s) > 8, do: String.slice(s, 0, 8) <> "…"
  defp shorten(s), do: to_string(s)
end
