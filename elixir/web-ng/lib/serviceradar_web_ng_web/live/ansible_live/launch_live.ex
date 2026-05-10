defmodule ServiceRadarWebNGWeb.AnsibleLive.LaunchLive do
  @moduledoc """
  Ad-hoc launch page for Ansible playbooks.

  Reachable at `/ansible/launch?devices=sr:a,sr:b,sr:c`. Operators
  arrive here from the (future) Device Actions modal in the inventory
  list or from a device detail page. The page:

    1. Loads the selected devices, surfaces any that aren't
       ansible-managed (or that belong to a different controller than
       the rest) so the operator can fix the selection before submit.
    2. Lets the operator pick a launchable Playbook from the catalog
       (`:awx`-sourced + has an awx_job_template_id).
    3. Accepts `extra_vars` as a free-form JSON object.
    4. On submit: delegates to `RunLauncher.launch/2`. On success,
       redirects to `/ansible/runs/:id`.

  Permission: `ansible.runs.launch`. The full Device Actions modal
  (inventory-list multi-select + device-detail single-device button)
  lands in a follow-up commit; this page is the destination it
  navigates to and the v1 surface for ad-hoc launches.
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNGWeb.Authorization,
    resource_module: ServiceRadar.Automation.Ansible.PlaybookRun

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Ansible.RunLauncher
  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.RBAC

  require Ash.Query
  require Logger

  @impl true
  def event_mapping do
    Map.merge(Permit.Phoenix.LiveView.default_event_mapping(), %{
      "validate" => :read,
      "launch" => :create
    })
  end

  @impl true
  def skip_preload, do: [:index, :read, :create]

  @impl true
  def mount(params, _session, socket) do
    scope = socket.assigns.current_scope

    cond do
      not RBAC.can?(scope, "ansible.runs.launch") ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have permission to launch Ansible runs.")
         |> push_navigate(to: ~p"/dashboard")}

      true ->
        uids = parse_device_uids(params["devices"])
        devices = load_devices(uids)
        playbooks = launchable_playbooks()

        {:ok,
         socket
         |> assign(:page_title, "Launch Ansible playbook")
         |> assign(:requested_uids, uids)
         |> assign(:devices, devices)
         |> assign(:playbooks, playbooks)
         |> assign(:selected_playbook_id, default_playbook_id(playbooks))
         |> assign(:extra_vars_text, "{}")
         |> assign(:launch_in_progress, false)}
    end
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply,
     socket
     |> assign(:selected_playbook_id, params["playbook_id"] || socket.assigns.selected_playbook_id)
     |> assign(:extra_vars_text, params["extra_vars"] || socket.assigns.extra_vars_text)}
  end

  def handle_event("launch", params, socket) do
    with {:ok, playbook_id} <- require_playbook(params["playbook_id"]),
         {:ok, extra_vars} <- parse_extra_vars(params["extra_vars"]),
         :ok <- ensure_can_launch(socket.assigns) do
      do_launch(socket, playbook_id, extra_vars)
    else
      {:error, :no_playbook} ->
        {:noreply, put_flash(socket, :error, "Pick a playbook before launching.")}

      {:error, {:bad_extra_vars, msg}} ->
        {:noreply, put_flash(socket, :error, "extra_vars JSON invalid: #{msg}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, launch_error_message(reason))}
    end
  end

  defp do_launch(socket, playbook_id, extra_vars) do
    actor = SystemActor.system(:ansible_launch_live)
    actor_id = socket.assigns.current_scope.user.id

    case RunLauncher.launch(
           %{
             playbook_id: playbook_id,
             device_uids: socket.assigns.requested_uids,
             extra_vars: extra_vars,
             requested_by_actor_id: actor_id
           },
           actor: actor
         ) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Launch dispatched. Watch the run unfold below.")
         |> push_navigate(to: ~p"/ansible/runs/#{run.id}")}

      {:error, reason} ->
        Logger.info("Ansible launch failed", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, launch_error_message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-4xl p-6 space-y-6">
      <header class="space-y-1">
        <h1 class="text-2xl font-semibold">Launch Ansible playbook</h1>
        <p class="text-sm text-base-content/70">
          {length(@requested_uids)} device{if length(@requested_uids) == 1, do: "", else: "s"}
          selected. Resolved {length(@devices)} from inventory.
        </p>
      </header>

      <section class="space-y-2">
        <h2 class="text-lg font-medium">Targets</h2>
        <div
          :if={@devices == []}
          class="rounded-lg border border-dashed border-base-300 p-6 text-sm text-base-content/70"
        >
          No devices selected. Append <code>?devices=sr:a,sr:b</code> to the URL, or use the
          Device Actions modal from the inventory list (coming soon).
        </div>

        <div :if={@devices != []} class="overflow-x-auto rounded-lg border border-base-300 bg-base-100">
          <table class="table table-zebra table-sm">
            <thead>
              <tr>
                <th>Hostname</th>
                <th>UID</th>
                <th>Ansible-managed</th>
                <th>AWX host</th>
                <th>Controller</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={device <- @devices}>
                <td>{device.hostname}</td>
                <td><code class="text-xs">{device.uid}</code></td>
                <td>
                  <span :if={device.ansible_managed} class="badge badge-success">yes</span>
                  <span :if={!device.ansible_managed} class="badge badge-error">no</span>
                </td>
                <td><code class="text-xs">{ref_field(device, "host_name")}</code></td>
                <td><code class="text-xs">{shorten(ref_field(device, "controller_id"))}</code></td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <.form for={%{}} as={:launch} phx-change="validate" phx-submit="launch" class="space-y-4">
        <div class="form-control">
          <label class="label">
            <span class="label-text">Playbook</span>
            <span class="label-text-alt text-xs text-base-content/60">
              {length(@playbooks)} launchable
            </span>
          </label>
          <select name="playbook_id" class="select select-bordered select-sm">
            <option value="" disabled selected={is_nil(@selected_playbook_id)}>
              — pick a playbook —
            </option>
            <option
              :for={playbook <- @playbooks}
              value={playbook.id}
              selected={playbook.id == @selected_playbook_id}
            >
              {playbook.name} ({playbook.source_type})
            </option>
          </select>
          <p :if={@playbooks == []} class="text-xs text-base-content/60 mt-2">
            No launchable playbooks. Either register an AWX controller (which auto-syncs job
            templates) or bind a git-sourced playbook to an AWX job_template_id.
          </p>
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text">extra_vars (JSON)</span>
            <span class="label-text-alt text-xs text-base-content/60">
              Merged into the AWX job template's defaults
            </span>
          </label>
          <textarea
            name="extra_vars"
            rows="4"
            class="textarea textarea-bordered font-mono text-xs"
            placeholder={"{\n  \"version\": \"1.2.3\"\n}"}
          >{@extra_vars_text}</textarea>
        </div>

        <div class="flex items-center justify-between pt-2">
          <.link navigate={~p"/ansible/runs"} class="link link-hover text-sm">← Back to runs</.link>
          <button
            type="submit"
            class="btn btn-primary"
            disabled={@playbooks == [] or @devices == [] or @launch_in_progress}
          >
            Launch
          </button>
        </div>
      </.form>
    </div>
    """
  end

  ## Helpers -------------------------------------------------------------------

  defp parse_device_uids(nil), do: []
  defp parse_device_uids(""), do: []

  defp parse_device_uids(s) when is_binary(s) do
    s
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_device_uids(_), do: []

  defp load_devices([]), do: []

  defp load_devices(uids) do
    actor = SystemActor.system(:ansible_launch_live)

    uids
    |> Enum.map(fn uid ->
      case Device.get_by_uid(uid, false, actor: actor) do
        {:ok, device} -> device
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp launchable_playbooks do
    actor = SystemActor.system(:ansible_launch_live)

    query =
      Playbook
      |> Ash.Query.filter(not is_nil(awx_job_template_id))
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(200)

    case Ash.read(query, actor: actor) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp default_playbook_id([]), do: nil
  defp default_playbook_id(_), do: nil

  defp require_playbook(nil), do: {:error, :no_playbook}
  defp require_playbook(""), do: {:error, :no_playbook}
  defp require_playbook(id) when is_binary(id), do: {:ok, id}

  defp parse_extra_vars(nil), do: {:ok, %{}}
  defp parse_extra_vars(""), do: {:ok, %{}}

  defp parse_extra_vars(s) when is_binary(s) do
    trimmed = String.trim(s)

    if trimmed == "" do
      {:ok, %{}}
    else
      case Jason.decode(trimmed) do
        {:ok, m} when is_map(m) -> {:ok, m}
        {:ok, _} -> {:error, {:bad_extra_vars, "must be a JSON object"}}
        {:error, %Jason.DecodeError{} = err} -> {:error, {:bad_extra_vars, Exception.message(err)}}
      end
    end
  end

  defp ensure_can_launch(%{devices: []}), do: {:error, :devices_required}

  defp ensure_can_launch(%{devices: devices}) do
    if Enum.all?(devices, & &1.ansible_managed) do
      :ok
    else
      {:error, :unmanaged_devices}
    end
  end

  defp launch_error_message(:devices_required), do: "Need at least one ansible-managed device."

  defp launch_error_message(:unmanaged_devices),
    do: "Selection contains devices that aren't ansible-managed. Remove them and retry."

  defp launch_error_message(:mixed_controllers),
    do: "Selection spans multiple AWX controllers. Narrow it to one controller."

  defp launch_error_message(:unknown_playbook), do: "Playbook not found."
  defp launch_error_message(:unknown_controller), do: "Controller not found."
  defp launch_error_message(:playbook_unbound), do: "Playbook isn't bound to an AWX job template."

  defp launch_error_message(:git_sourced_not_supported_v1),
    do: "Git-sourced playbooks need an AWX template binding before they're launchable."

  defp launch_error_message(other), do: "Launch failed: #{inspect(other)}" |> String.slice(0, 240)

  defp ref_field(device, key) do
    ref = Map.get(device, :ansible_inventory_ref) || %{}
    Map.get(ref, key) || Map.get(ref, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(Map.get(device, :ansible_inventory_ref) || %{}, key)
  end

  defp shorten(nil), do: "—"
  defp shorten(s) when is_binary(s) and byte_size(s) > 8, do: String.slice(s, 0, 8) <> "…"
  defp shorten(s), do: to_string(s)
end
