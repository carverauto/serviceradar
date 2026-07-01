defmodule ServiceRadarWebNGWeb.Settings.RemoteAccessHostKeysLive do
  @moduledoc """
  Operator review page for remote-access SSH host-key trust state.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Edge.RemoteAccessHostKey
  alias ServiceRadar.Edge.RemoteAccessHostKeys
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @current_path "/settings/networks/host-keys"
  @manage_permission "settings.remote_access_host_keys.manage"
  @statuses ~w(pending trusted conflict rotated revoked rejected)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can_manage?(scope) do
      {:ok,
       socket
       |> assign(:page_title, "Remote Access Host Keys")
       |> assign(:current_path, @current_path)
       |> assign(:host_keys, [])
       |> assign(:filters, %{"status" => "", "target_host" => "", "agent_id" => ""})
       |> assign(:loading?, true)
       |> assign(:rotation_host_key, nil)
       |> assign(:rotation_candidates, [])}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage remote access host keys")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if fresh_can_manage?(socket.assigns.current_scope) do
      filters = normalize_filters(params)

      socket =
        socket
        |> assign(:current_path, @current_path)
        |> assign(:filters, filters)

      if connected?(socket) do
        {:noreply, load_host_keys(socket)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, unauthorized(socket)}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    authorize_manage_event(socket, fn ->
      {:noreply, push_patch(socket, to: filter_path(params))}
    end)
  end

  def handle_event("clear_filters", _params, socket) do
    authorize_manage_event(socket, fn ->
      {:noreply, push_patch(socket, to: ~p"/settings/networks/host-keys")}
    end)
  end

  def handle_event("trust_host_key", %{"id" => id}, socket) do
    authorize_manage_event(socket, fn ->
      case RemoteAccessHostKeys.trust(id, scope: socket.assigns.current_scope) do
        {:ok, _host_key} ->
          {:noreply,
           socket
           |> put_flash(:info, "Host key trusted")
           |> load_host_keys()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to trust host key: #{format_error(reason)}")}
      end
    end)
  end

  def handle_event("revoke_host_key", %{"id" => id}, socket) do
    authorize_manage_event(socket, fn ->
      case RemoteAccessHostKeys.revoke(id,
             scope: socket.assigns.current_scope,
             reason: "operator revoked"
           ) do
        {:ok, _host_key} ->
          {:noreply,
           socket
           |> put_flash(:info, "Host key revoked")
           |> assign(:rotation_host_key, nil)
           |> assign(:rotation_candidates, [])
           |> load_host_keys()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to revoke host key: #{format_error(reason)}")}
      end
    end)
  end

  def handle_event("reject_host_key", %{"id" => id}, socket) do
    authorize_manage_event(socket, fn ->
      case RemoteAccessHostKeys.reject(id,
             scope: socket.assigns.current_scope,
             reason: "operator rejected"
           ) do
        {:ok, _host_key} ->
          {:noreply,
           socket
           |> put_flash(:info, "Host key rejected")
           |> assign(:rotation_host_key, nil)
           |> assign(:rotation_candidates, [])
           |> load_host_keys()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to reject host key: #{format_error(reason)}")}
      end
    end)
  end

  def handle_event("show_rotate", %{"id" => id}, socket) do
    authorize_manage_event(socket, fn ->
      scope = socket.assigns.current_scope

      with {:ok, %RemoteAccessHostKey{} = host_key} <- RemoteAccessHostKeys.get(id, scope: scope),
           {:ok, candidates} <- rotation_candidates(host_key, scope) do
        {:noreply,
         socket
         |> assign(:rotation_host_key, host_key)
         |> assign(:rotation_candidates, candidates)}
      else
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to prepare rotation: #{format_error(reason)}")}
      end
    end)
  end

  def handle_event("cancel_rotation", _params, socket) do
    authorize_manage_event(socket, fn ->
      {:noreply, close_rotation(socket)}
    end)
  end

  def handle_event("rotate_host_key", %{"rotation" => %{"replacement_host_key_id" => replacement_id} = params}, socket) do
    authorize_manage_event(socket, fn ->
      with %RemoteAccessHostKey{} = old_host_key <- socket.assigns.rotation_host_key,
           {:ok, _result} <-
             RemoteAccessHostKeys.rotate(old_host_key.id, replacement_id,
               scope: socket.assigns.current_scope,
               reason: blank_to_nil(params["reason"]) || "operator rotation"
             ) do
        {:noreply,
         socket
         |> put_flash(:info, "Host key rotated")
         |> close_rotation()
         |> load_host_keys()}
      else
        nil ->
          {:noreply, put_flash(socket, :error, "No host key selected for rotation")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to rotate host key: #{format_error(reason)}")}
      end
    end)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :statuses, @statuses)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        settings_ui={@settings_ui}
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <:legacy>
          <div class="space-y-4">
            <.settings_nav current_path={@current_path} current_scope={@current_scope} />
            <.network_nav current_path={@current_path} current_scope={@current_scope} />
          </div>
        </:legacy>

        <section class="space-y-4">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h1 class="text-xl font-semibold">Remote Access Host Keys</h1>
              <p class="mt-1 text-sm text-base-content/70">
                Review SSH host keys observed by routed agents before trusting console and SSH targets.
              </p>
            </div>
          </div>

          <form
            id="host-key-filters"
            class="grid gap-3 rounded-lg border border-base-200 bg-base-100 p-4 md:grid-cols-[1fr_1fr_14rem_auto]"
            phx-submit="filter"
          >
            <label class="form-control">
              <span class="label-text">Target host</span>
              <input
                type="text"
                name="target_host"
                value={@filters["target_host"]}
                class="input input-bordered input-sm"
              />
            </label>
            <label class="form-control">
              <span class="label-text">Agent</span>
              <input
                type="text"
                name="agent_id"
                value={@filters["agent_id"]}
                class="input input-bordered input-sm"
              />
            </label>
            <label class="form-control">
              <span class="label-text">Status</span>
              <select name="status" class="select select-bordered select-sm">
                <option value="" selected={@filters["status"] == ""}>All</option>
                <option
                  :for={status <- @statuses}
                  value={status}
                  selected={@filters["status"] == status}
                >
                  {status_label(status)}
                </option>
              </select>
            </label>
            <div class="flex items-end gap-2">
              <button type="submit" class="btn btn-primary btn-sm">Filter</button>
              <button type="button" class="btn btn-ghost btn-sm" phx-click="clear_filters">
                Clear
              </button>
            </div>
          </form>

          <div class="overflow-hidden rounded-lg border border-base-200 bg-base-100">
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Target</th>
                    <th>Agent</th>
                    <th>Fingerprint</th>
                    <th>Status</th>
                    <th>Source</th>
                    <th>Seen</th>
                    <th>Last seen</th>
                    <th class="text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@loading?}>
                    <td colspan="8" class="py-8 text-center text-sm text-base-content/60">
                      Loading host keys.
                    </td>
                  </tr>
                  <tr :if={!@loading? and @host_keys == []}>
                    <td colspan="8" class="py-8 text-center text-sm text-base-content/60">
                      No host keys found.
                    </td>
                  </tr>
                  <tr :for={host_key <- @host_keys}>
                    <td>
                      <div class="font-medium">{host_key.target_host}</div>
                      <div class="text-xs text-base-content/60">
                        {host_key.protocol}:{host_key.target_port}
                      </div>
                    </td>
                    <td>
                      <div>{host_key.agent_id}</div>
                      <div :if={host_key.gateway_id} class="text-xs text-base-content/60">
                        {host_key.gateway_id}
                      </div>
                    </td>
                    <td>
                      <div class="font-mono text-xs">{host_key.fingerprint_sha256}</div>
                      <div class="text-xs text-base-content/60">{host_key.key_type}</div>
                    </td>
                    <td>
                      <span class={["badge badge-sm", status_badge_class(host_key.status)]}>
                        {status_label(host_key.status)}
                      </span>
                    </td>
                    <td>{source_label(host_key.source)}</td>
                    <td>{host_key.seen_count}</td>
                    <td>{format_datetime(host_key.last_seen_at)}</td>
                    <td class="text-right">
                      <div class="flex flex-wrap justify-end gap-2">
                        <button
                          :if={host_key.status == :pending}
                          type="button"
                          class="btn btn-primary btn-xs"
                          phx-click="trust_host_key"
                          phx-value-id={host_key.id}
                        >
                          Trust
                        </button>
                        <button
                          :if={host_key.status in [:pending, :conflict]}
                          type="button"
                          class="btn btn-error btn-outline btn-xs"
                          phx-click="reject_host_key"
                          phx-value-id={host_key.id}
                        >
                          Reject
                        </button>
                        <button
                          :if={host_key.status == :trusted}
                          type="button"
                          class="btn btn-ghost btn-xs"
                          phx-click="show_rotate"
                          phx-value-id={host_key.id}
                        >
                          Rotate
                        </button>
                        <button
                          :if={host_key.status not in [:revoked, :rejected]}
                          type="button"
                          class="btn btn-error btn-outline btn-xs"
                          phx-click="revoke_host_key"
                          phx-value-id={host_key.id}
                        >
                          Revoke
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>

        <.rotation_modal
          :if={@rotation_host_key}
          host_key={@rotation_host_key}
          candidates={@rotation_candidates}
        />
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  attr(:host_key, :any, required: true)
  attr(:candidates, :list, required: true)

  defp rotation_modal(assigns) do
    ~H"""
    <dialog class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h2 class="text-lg font-semibold">Rotate Host Key</h2>
        <p class="mt-1 text-sm text-base-content/70">
          {@host_key.target_host}:{@host_key.target_port} via {@host_key.agent_id}
        </p>

        <form class="mt-4 space-y-4" phx-submit="rotate_host_key">
          <label class="form-control">
            <span class="label-text">Replacement key</span>
            <select
              name="rotation[replacement_host_key_id]"
              class="select select-bordered"
              disabled={@candidates == []}
            >
              <option value="">Select a replacement</option>
              <option :for={candidate <- @candidates} value={candidate.id}>
                {candidate.fingerprint_sha256} ({status_label(candidate.status)})
              </option>
            </select>
          </label>

          <label class="form-control">
            <span class="label-text">Reason</span>
            <input
              type="text"
              name="rotation[reason]"
              value="operator rotation"
              class="input input-bordered"
            />
          </label>

          <p :if={@candidates == []} class="text-sm text-warning">
            No replacement keys have been observed for this target.
          </p>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="cancel_rotation">Cancel</button>
            <button type="submit" class="btn btn-primary" disabled={@candidates == []}>
              Rotate
            </button>
          </div>
        </form>
      </div>
      <button class="modal-backdrop" phx-click="cancel_rotation">Close</button>
    </dialog>
    """
  end

  defp load_host_keys(socket) do
    case RemoteAccessHostKeys.list(active_filters(socket.assigns.filters), scope: socket.assigns.current_scope) do
      {:ok, host_keys} ->
        socket
        |> assign(:host_keys, host_keys)
        |> assign(:loading?, false)

      {:error, reason} ->
        socket
        |> assign(:host_keys, [])
        |> assign(:loading?, false)
        |> put_flash(:error, "Failed to load host keys: #{format_error(reason)}")
    end
  end

  defp rotation_candidates(%RemoteAccessHostKey{} = host_key, scope) do
    filters = %{
      "agent_id" => host_key.agent_id,
      "target_host" => host_key.target_host
    }

    with {:ok, host_keys} <- RemoteAccessHostKeys.list(filters, scope: scope) do
      candidates =
        Enum.filter(host_keys, fn candidate ->
          candidate.id != host_key.id and
            candidate.target_port == host_key.target_port and
            candidate.protocol == host_key.protocol and
            candidate.status in [:pending, :conflict, :trusted]
        end)

      {:ok, candidates}
    end
  end

  defp normalize_filters(params) do
    %{
      "status" => filter_value(params["status"]),
      "target_host" => filter_value(params["target_host"]),
      "agent_id" => filter_value(params["agent_id"])
    }
  end

  defp filter_path(params) do
    ~p"/settings/networks/host-keys?#{params |> normalize_filters() |> active_filters()}"
  end

  defp active_filters(filters) do
    filters
    |> Enum.reject(fn {_key, value} -> value == "" end)
    |> Map.new()
  end

  defp filter_value(value) when is_binary(value), do: String.trim(value)
  defp filter_value(_value), do: ""

  defp close_rotation(socket) do
    socket
    |> assign(:rotation_host_key, nil)
    |> assign(:rotation_candidates, [])
  end

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp authorize_manage_event(socket, fun) when is_function(fun, 0) do
    if fresh_can_manage?(socket.assigns.current_scope) do
      fun.()
    else
      {:noreply, unauthorized(socket)}
    end
  end

  defp unauthorized(socket) do
    socket
    |> put_flash(:error, "Not authorized to manage remote access host keys")
    |> redirect(to: ~p"/settings/profile")
  end

  defp fresh_can_manage?(%{user: user}) when not is_nil(user) do
    ServiceRadar.Identity.RBAC.clear_process_cache()
    ServiceRadar.Identity.RBAC.has_permission?(user, @manage_permission)
  end

  defp fresh_can_manage?(scope), do: can_manage?(scope)

  defp can_manage?(scope), do: RBAC.can?(scope, @manage_permission)

  defp status_label(status), do: status |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp source_label(source), do: source |> to_string() |> String.replace("_", " ")

  defp status_badge_class(:trusted), do: "badge-success"
  defp status_badge_class(:conflict), do: "badge-error"
  defp status_badge_class(:pending), do: "badge-warning"
  defp status_badge_class(:rotated), do: "badge-info"
  defp status_badge_class(:revoked), do: "badge-neutral"
  defp status_badge_class(:rejected), do: "badge-neutral"
  defp status_badge_class(_status), do: "badge-ghost"

  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(value), do: inspect(value)

  defp format_error(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp format_error(%Ash.Error.Forbidden{} = error), do: Exception.message(error)
  defp format_error({field, reason}), do: "#{field}: #{inspect(reason)}"
  defp format_error(reason) when is_atom(reason), do: reason |> to_string() |> String.replace("_", " ")
  defp format_error(reason), do: inspect(reason)
end
