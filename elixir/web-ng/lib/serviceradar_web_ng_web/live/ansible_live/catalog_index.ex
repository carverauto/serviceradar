defmodule ServiceRadarWebNGWeb.AnsibleLive.CatalogIndex do
  @moduledoc """
  Browser for the Ansible playbook catalog.

  Shows both git-sourced and AWX-sourced `Playbook` rows side by side.
  Filterable by source type (all / git / awx), launchability
  (anything / launchable / unbound), and parse status. Operators use
  this surface to discover which playbooks exist before kicking off
  a run from `/devices` → Run Task.

  Permission: `ansible.catalog.view`. Read-only -- launch flow lives
  on `/ansible/launch` (reached via the inventory list / device detail
  Run Task button).
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
      playbooks = list_playbooks(filters)

      {:ok,
       socket
       |> assign(:page_title, "Ansible playbook catalog")
       |> assign(:filters, filters)
       |> assign(:source_filters, @source_filters)
       |> assign(:binding_filters, @binding_filters)
       |> assign(:playbook_count, length(playbooks))
       |> stream(:playbooks, playbooks, reset: true)}
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
    playbooks = list_playbooks(filters)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:playbook_count, length(playbooks))
     |> stream(:playbooks, playbooks, reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-7xl p-6 space-y-4">
      <header class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-semibold">Ansible playbook catalog</h1>
          <p class="text-sm text-base-content/70">
            {@playbook_count} playbook{if @playbook_count == 1, do: "", else: "s"} shown
            (capped at {@page_limit}).
          </p>
        </div>
        <button type="button" class="btn btn-sm btn-ghost" phx-click="refresh">Refresh</button>
      </header>

      <div class="flex flex-wrap items-end gap-3">
        <div>
          <p class="text-xs text-base-content/60 mb-1">Source</p>
          <div class="join">
            <button
              :for={src <- @source_filters}
              type="button"
              phx-click="filter_source"
              phx-value-value={src}
              class={["btn btn-xs join-item", src == @filters.source && "btn-primary"]}
            >
              {src}
            </button>
          </div>
        </div>

        <div>
          <p class="text-xs text-base-content/60 mb-1">Binding</p>
          <div class="join">
            <button
              :for={state <- @binding_filters}
              type="button"
              phx-click="filter_binding"
              phx-value-value={state}
              class={["btn btn-xs join-item", state == @filters.binding && "btn-primary"]}
            >
              {state}
            </button>
          </div>
        </div>

        <form phx-change="filter_search" class="flex-1 min-w-[16rem] max-w-md">
          <input
            type="text"
            name="value"
            value={@filters.search}
            placeholder="Filter by name / description / tag…"
            class="input input-sm input-bordered w-full"
            phx-debounce="250"
          />
        </form>
      </div>

      <div :if={@playbook_count == 0} class="rounded-lg border border-dashed border-base-300 p-8 text-center text-sm text-base-content/70">
        No playbooks match the current filters.
        <p class="mt-2">
          New AWX controllers and git repositories sync in the background;
          the catalog populates within the configured sync interval.
        </p>
      </div>

      <div :if={@playbook_count > 0} class="overflow-x-auto rounded-lg border border-base-300 bg-base-100">
        <table class="table table-zebra table-sm">
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
            <tr :for={{id, pb} <- @playbooks} id={id}>
              <td>
                <div class="font-medium">{pb.name}</div>
                <div :if={pb.description} class="text-xs text-base-content/60">{pb.description}</div>
                <div :if={pb.path} class="text-xs text-base-content/60 font-mono mt-1">{pb.path}</div>
              </td>
              <td>
                <span class={["badge badge-sm", source_badge_class(pb.source_type)]}>{pb.source_type}</span>
              </td>
              <td>
                <code class="text-xs">{shorten(pb.repository_id || pb.controller_id)}</code>
              </td>
              <td>
                <span :if={pb.awx_job_template_id} class="badge badge-sm badge-success">{pb.awx_job_template_id}</span>
                <span :if={!pb.awx_job_template_id} class="badge badge-sm badge-warning">unbound</span>
              </td>
              <td>
                <div class="flex flex-wrap gap-1">
                  <span :for={tag <- pb.tags || []} class="badge badge-xs badge-ghost">{tag}</span>
                  <span :if={pb.tags == []} class="text-xs text-base-content/60">—</span>
                </div>
              </td>
              <td>
                <span class={["badge badge-sm", parse_badge_class(pb.parse_status)]}>{pb.parse_status}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
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

  defp apply_binding_filter(query, "launchable"),
    do: Ash.Query.filter(query, not is_nil(awx_job_template_id))

  defp apply_binding_filter(query, "unbound"),
    do: Ash.Query.filter(query, is_nil(awx_job_template_id))

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

  defp source_badge_class(:git), do: "badge-info"
  defp source_badge_class(:awx), do: "badge-primary"
  defp source_badge_class(_), do: "badge-ghost"

  defp parse_badge_class(:ok), do: "badge-success"
  defp parse_badge_class(:error), do: "badge-error"
  defp parse_badge_class(:pending), do: "badge-ghost"
  defp parse_badge_class(_), do: "badge-ghost"

  defp shorten(nil), do: "—"
  defp shorten(s) when is_binary(s) and byte_size(s) > 8, do: String.slice(s, 0, 8) <> "…"
  defp shorten(s), do: to_string(s)
end
