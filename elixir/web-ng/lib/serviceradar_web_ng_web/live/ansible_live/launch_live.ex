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
  alias ServiceRadar.Automation.Ansible.VariableSchema
  alias ServiceRadar.Automation.Ansible.VariableSchema.Var
  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.RBAC

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

    if RBAC.can?(scope, "ansible.runs.launch") do
      uids = parse_device_uids(params["devices"])
      devices = load_devices(uids)
      playbooks = launchable_playbooks()

      {:ok,
       socket
       |> assign(:page_title, "Launch Ansible playbook")
       |> assign(:requested_uids, uids)
       |> assign(:devices, devices)
       |> assign(:playbooks, playbooks)
       |> assign(:selected_playbook_id, nil)
       |> assign(:vars, [])
       |> assign(:var_values, %{})
       |> assign(:extra_vars_text, "{}")
       |> assign(:show_raw_override, false)
       |> assign(:launch_in_progress, false)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to launch Ansible runs.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("validate", params, socket) do
    playbook_id = params["playbook_id"] || socket.assigns.selected_playbook_id

    socket =
      socket
      |> assign(:extra_vars_text, params["extra_vars"] || socket.assigns.extra_vars_text)
      |> assign(:show_raw_override, params["show_raw_override"] == "on" || socket.assigns.show_raw_override)
      |> assign(:var_values, Map.merge(socket.assigns.var_values, var_values_from_params(socket.assigns.vars, params)))

    socket =
      if playbook_id == socket.assigns.selected_playbook_id do
        socket
      else
        playbook = Enum.find(socket.assigns.playbooks, &(&1.id == playbook_id))
        vars = if playbook, do: VariableSchema.from_playbook(playbook), else: []

        socket
        |> assign(:selected_playbook_id, playbook_id)
        |> assign(:vars, vars)
        |> assign(:var_values, defaults_for(vars))
      end

    {:noreply, socket}
  end

  def handle_event("launch", params, socket) do
    with {:ok, playbook_id} <- require_playbook(params["playbook_id"]),
         {:ok, override_vars} <- parse_extra_vars(params["extra_vars"]),
         :ok <- ensure_can_launch(socket.assigns) do
      form_vars = VariableSchema.extra_vars_from_form(socket.assigns.vars, params)
      # Override JSON takes precedence over typed inputs so operators
      # can poke values not in the schema.
      extra_vars = Map.merge(form_vars, override_vars)
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
          {length(@requested_uids)} device{if length(@requested_uids) == 1, do: "", else: "s"} selected. Resolved {length(
            @devices
          )} from inventory.
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

        <div
          :if={@devices != []}
          class="overflow-x-auto rounded-lg border border-base-300 bg-base-100"
        >
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

        <div :if={@vars != []} class="space-y-3">
          <h3 class="text-sm font-medium">Variables</h3>
          <p class="text-xs text-base-content/60">
            Derived from the playbook's {variable_source_label(@selected_playbook_id, @playbooks)}.
          </p>
          <.var_input :for={var <- @vars} var={var} value={Map.get(@var_values, var.name)} />
        </div>

        <div :if={@vars == [] and @selected_playbook_id} class="text-xs text-base-content/60">
          This playbook has no declared variables. Use the raw override below for any
          extra_vars AWX needs.
        </div>

        <div class="form-control">
          <label class="label cursor-pointer justify-start gap-2">
            <input
              type="checkbox"
              name="show_raw_override"
              class="checkbox checkbox-xs"
              checked={@show_raw_override}
            />
            <span class="label-text text-xs">Override extra_vars as raw JSON</span>
            <span class="label-text-alt text-xs text-base-content/60">
              Merged on top of the typed inputs above
            </span>
          </label>

          <textarea
            :if={@show_raw_override}
            name="extra_vars"
            rows="4"
            class="textarea textarea-bordered font-mono text-xs"
            placeholder={"{\n  \"region\": \"us-east-1\"\n}"}
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

  ## Internals -----------------------------------------------------------------

  defp var_values_from_params(vars, params) when is_list(vars) and is_map(params) do
    Enum.reduce(vars, %{}, fn %Var{name: name}, acc ->
      case Map.get(params, name) do
        nil -> acc
        v -> Map.put(acc, name, v)
      end
    end)
  end

  defp defaults_for(vars) do
    Enum.reduce(vars, %{}, fn %Var{} = var, acc ->
      case var.default do
        nil -> acc
        d -> Map.put(acc, var.name, to_string_default(d))
      end
    end)
  end

  defp to_string_default(d) when is_binary(d), do: d
  defp to_string_default(d) when is_integer(d) or is_float(d), do: to_string(d)
  defp to_string_default(true), do: "true"
  defp to_string_default(false), do: "false"
  defp to_string_default(d), do: inspect(d)

  ## Variable input component --------------------------------------------------

  attr :var, :any, required: true
  attr :value, :any, default: nil

  defp var_input(%{var: %Var{type: :textarea}} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text">{@var.label}</span>
        <span :if={@var.required} class="label-text-alt text-xs text-error">required</span>
      </label>
      <textarea name={@var.name} rows="3" class="textarea textarea-bordered text-sm">{@value}</textarea>
      <p :if={@var.help} class="text-xs text-base-content/60 mt-1">{@var.help}</p>
    </div>
    """
  end

  defp var_input(%{var: %Var{type: :password}} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text">{@var.label}</span>
        <span class="label-text-alt text-xs text-base-content/60">stored only at launch time</span>
      </label>
      <input
        type="password"
        name={@var.name}
        value={@value}
        class="input input-bordered input-sm font-mono"
        autocomplete="off"
      />
    </div>
    """
  end

  defp var_input(%{var: %Var{type: :integer}} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text">{@var.label}</span>
        <span :if={@var.required} class="label-text-alt text-xs text-error">required</span>
      </label>
      <input
        type="number"
        name={@var.name}
        value={@value}
        min={@var.min}
        max={@var.max}
        step="1"
        class="input input-bordered input-sm"
      />
    </div>
    """
  end

  defp var_input(%{var: %Var{type: :float}} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text">{@var.label}</span>
      </label>
      <input
        type="number"
        name={@var.name}
        value={@value}
        step="any"
        class="input input-bordered input-sm"
      />
    </div>
    """
  end

  defp var_input(%{var: %Var{type: :select}} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text">{@var.label}</span>
      </label>
      <select name={@var.name} class="select select-bordered select-sm">
        <option value="" selected={is_nil(@value) or @value == ""}>—</option>
        <option :for={choice <- @var.choices} value={choice} selected={@value == choice}>
          {choice}
        </option>
      </select>
    </div>
    """
  end

  defp var_input(%{var: %Var{type: :multiselect}} = assigns) do
    selected = if is_list(assigns.value), do: assigns.value, else: []
    assigns = assign(assigns, :selected_choices, selected)

    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text">{@var.label}</span>
        <span class="label-text-alt text-xs text-base-content/60">tick all that apply</span>
      </label>
      <div class="flex flex-wrap gap-3 px-1">
        <label :for={choice <- @var.choices} class="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            name={"#{@var.name}[]"}
            value={choice}
            checked={choice in @selected_choices}
            class="checkbox checkbox-sm"
          />
          {choice}
        </label>
      </div>
    </div>
    """
  end

  defp var_input(assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text">{@var.label}</span>
        <span :if={@var.required} class="label-text-alt text-xs text-error">required</span>
      </label>
      <input
        type="text"
        name={@var.name}
        value={@value}
        class="input input-bordered input-sm"
        placeholder={@var.default && to_string(@var.default)}
      />
      <p :if={@var.help} class="text-xs text-base-content/60 mt-1">{@var.help}</p>
    </div>
    """
  end

  defp variable_source_label(nil, _playbooks), do: "schema"

  defp variable_source_label(playbook_id, playbooks) do
    case Enum.find(playbooks, &(&1.id == playbook_id)) do
      %{source_type: :awx} -> "AWX survey_spec"
      %{source_type: :git} -> "vars_prompt block"
      _ -> "schema"
    end
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

    # Canonical launchable-playbooks read (single source of truth shared with the
    # device-details Ansible panel). No controller scope here: the ad-hoc page
    # lists launchable playbooks across all controllers.
    case Playbook.list_launchable(%{}, actor: actor) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

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
    if Enum.all?(devices, &ansible_managed?/1) do
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

  defp launch_error_message(other), do: String.slice("Launch failed: #{inspect(other)}", 0, 240)

  defp ansible_managed?(device) do
    ref = ansible_inventory_ref(device)

    Map.get(device, :ansible_managed) == true or
      Map.get(device, "ansible_managed") == true or
      Map.get(ref, "managed") == true or
      Map.get(ref, :managed) == true
  end

  defp ref_field(device, key) do
    ref = ansible_inventory_ref(device)
    Map.get(ref, key) || Map.get(ref, atom_ref_key(key))
  end

  defp atom_ref_key("controller_id"), do: :controller_id
  defp atom_ref_key("host_id"), do: :host_id
  defp atom_ref_key("host_name"), do: :host_name
  defp atom_ref_key(_), do: nil

  defp ansible_inventory_ref(device) when is_map(device) do
    Map.get(device, :ansible_inventory_ref) ||
      Map.get(device, "ansible_inventory_ref") ||
      get_in(Map.get(device, :metadata) || %{}, ["ansible_inventory_ref"]) ||
      get_in(Map.get(device, "metadata") || %{}, ["ansible_inventory_ref"]) ||
      %{}
  end

  defp shorten(nil), do: "—"
  defp shorten(s) when is_binary(s) and byte_size(s) > 8, do: String.slice(s, 0, 8) <> "…"
  defp shorten(s), do: to_string(s)
end
