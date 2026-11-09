defmodule ServiceRadarWebNGWeb.Settings.ClusterLive.DeadLetters do
  @moduledoc """
  The Settings -> Cluster "Dead letters" section: what the edge-record dead-letter stream holds,
  grouped by output contract and failure reason, with replay and purge per group and a purge of
  everything held (`ServiceRadarWebNG.Edge.DeadLetters`).

  The cluster page renders it only for a user who may manage the edge pipeline
  (`settings.edge.manage`), and every action re-checks that permission against the user's current
  record before it runs. Nothing is read until the operator asks: reading the stream walks it
  message by message, so it stays off the page's ten-second refresh. Actions run in the
  background, so a large replay or purge never blocks the LiveView, and each one names its exact
  count in a confirmation first.
  """

  use ServiceRadarWebNGWeb, :live_component

  alias ServiceRadarWebNG.Edge.DeadLetters
  alias ServiceRadarWebNG.RBAC

  @permission "settings.edge.manage"

  @impl true
  def mount(socket) do
    {:ok, assign(socket, inventory: nil, loading: false, confirm: nil, running: nil, result: nil, denied: false)}
  end

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, Map.take(assigns, [:id, :current_scope]))}

  @impl true
  def handle_event("load", _params, socket), do: {:noreply, socket |> assign(:denied, false) |> load()}

  def handle_event("confirm", %{"action" => action} = params, socket) when action in ["replay", "purge"] do
    {:noreply, assign(socket, confirm: confirmation(socket, action, params["group"]), denied: false)}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("execute", _params, %{assigns: %{confirm: %{} = confirm}} = socket) do
    case RBAC.authorize_current(socket.assigns.current_scope, [@permission]) do
      {:ok, scope} ->
        actor = actor(scope)
        group = confirm.group

        task =
          case confirm.action do
            :replay -> fn -> DeadLetters.replay(group, actor) end
            :purge -> fn -> DeadLetters.purge(group, actor) end
          end

        {:noreply,
         socket
         |> assign(current_scope: scope, confirm: nil, running: confirm, result: nil)
         |> start_async(:action, task)}

      {:error, _reason} ->
        {:noreply, assign(socket, confirm: nil, denied: true)}
    end
  end

  def handle_event("execute", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:inventory, {:ok, result}, socket), do: {:noreply, assign(socket, inventory: result, loading: false)}

  def handle_async(:inventory, {:exit, reason}, socket),
    do: {:noreply, assign(socket, inventory: {:error, reason}, loading: false)}

  def handle_async(:action, {:ok, result}, socket) do
    {:noreply, socket |> assign(result: {socket.assigns.running, result}, running: nil) |> load()}
  end

  def handle_async(:action, {:exit, reason}, socket) do
    {:noreply, socket |> assign(result: {socket.assigns.running, {:error, reason}}, running: nil) |> load()}
  end

  defp load(socket) do
    socket
    |> assign(:loading, true)
    |> start_async(:inventory, fn -> DeadLetters.inventory() end)
  end

  # The group index refers to the inventory the operator is looking at; "all" is every dead
  # letter it read. Each action is bounded to that inventory's last sequence, so the count shown
  # is the most it can act on.
  defp confirmation(socket, action, "all") do
    case socket.assigns.inventory do
      {:ok, %{groups: groups} = inventory} ->
        %{
          action: String.to_existing_atom(action),
          group: %{through_sequence: inventory.through_sequence},
          label: if(inventory.complete, do: "every held dead letter", else: "every dead letter inspected"),
          count: Enum.sum(Enum.map(groups, & &1.count))
        }

      _ ->
        nil
    end
  end

  defp confirmation(socket, action, index) do
    with {:ok, %{groups: groups} = inventory} <- socket.assigns.inventory,
         {i, ""} <- Integer.parse(to_string(index)),
         %{} = group <- Enum.at(groups, i) do
      %{
        action: String.to_existing_atom(action),
        group: group |> Map.take([:contract, :reason]) |> Map.put(:through_sequence, inventory.through_sequence),
        label: "#{contract_label(group)} dead-lettered for #{reason_label(group)}",
        count: group.count
      }
    else
      _ -> nil
    end
  end

  defp actor(%{user: user}) when is_map(user), do: %{id: Map.get(user, :id), email: Map.get(user, :email)}

  defp actor(_scope), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.ui_panel>
        <:header>
          <div class="flex w-full items-start justify-between gap-3">
            <div>
              <div class="text-sm font-semibold">Dead letters</div>
              <p class="text-xs text-sr-muted">
                Edge records no projector could take, held on the dead-letter stream until they are
                replayed or purged. Replay a group once its cause is fixed; purge records newer
                deliveries have already superseded. A purge deletes the only copy.
              </p>
            </div>
            <.ui_button
              id="dead-letters-load"
              type="button"
              size="sm"
              variant="neutral"
              phx-click="load"
              phx-target={@myself}
              disabled={@loading or not is_nil(@running)}
            >
              <.ui_spinner :if={@loading} size="xs" />
              {if is_nil(@inventory), do: "Inspect", else: "Reload"}
            </.ui_button>
          </div>
        </:header>

        <div
          :if={@denied}
          id="dead-letters-denied"
          class="mb-3 rounded border border-error/40 px-3 py-2 text-xs text-error"
        >
          You no longer have permission to manage edge dead letters; nothing was replayed or purged.
        </div>

        <.action_result :if={@result} result={@result} />

        <div :if={@running} id="dead-letters-running" class="mb-3 flex items-center gap-2 text-xs">
          <.ui_spinner size="xs" />
          {action_verb(@running.action)} {@running.label}…
        </div>

        <div :if={is_nil(@inventory)} class="py-4 text-center text-xs text-sr-muted">
          Inspect reads the dead-letter stream and groups what it holds.
        </div>

        <div
          :if={match?({:error, _}, @inventory)}
          id="dead-letters-error"
          class="py-4 text-center text-xs text-error"
        >
          Could not read the dead-letter stream: {inventory_error(@inventory)}
        </div>

        <.groups_table
          :if={match?({:ok, _}, @inventory)}
          inventory={elem(@inventory, 1)}
          busy={not is_nil(@running)}
          target={@myself}
          timezone={@current_scope.user.timezone || "Etc/UTC"}
        />
      </.ui_panel>

      <.ui_modal
        :if={@confirm}
        id="dead-letters-confirm"
        size="sm"
        on_cancel="cancel"
        on_cancel_target={@myself}
      >
        <:title>{confirm_title(@confirm)}</:title>
        <p>
          {action_verb(@confirm.action)} <strong>{@confirm.count}</strong> records: {@confirm.label}.
        </p>
        <p :if={@confirm.action == :purge} class="text-sm text-sr-muted">
          This deletes them from the dead-letter stream, where each is the only copy of its record.
          It cannot be undone.
        </p>
        <p :if={@confirm.action == :replay} class="text-sm text-sr-muted">
          Each record is republished to the stream it came from. One the ledger already holds writes
          nothing; one that fails again is dead-lettered again.
        </p>
        <:actions>
          <.ui_button
            type="button"
            size="sm"
            variant="neutral"
            phx-click="cancel"
            phx-target={@myself}
          >
            Cancel
          </.ui_button>
          <.ui_button
            id="dead-letters-execute"
            type="button"
            size="sm"
            variant={if @confirm.action == :purge, do: "danger", else: "warning"}
            phx-click="execute"
            phx-target={@myself}
          >
            {confirm_title(@confirm)}
          </.ui_button>
        </:actions>
      </.ui_modal>
    </div>
    """
  end

  attr(:inventory, :map, required: true)
  attr(:busy, :boolean, default: false)
  attr(:target, :any, default: nil)
  attr(:timezone, :string, default: "Etc/UTC")

  @doc "The held dead letters, one row per contract and reason, with each row's actions."
  def groups_table(assigns) do
    ~H"""
    <div :if={@inventory.groups == []} id="dead-letters-empty" class="py-4 text-center text-xs">
      The dead-letter stream holds nothing.
    </div>

    <div :if={@inventory.groups != []} class="space-y-2">
      <p :if={not @inventory.complete} id="dead-letters-partial" class="text-xs text-warning">
        Showing the first {@inventory.scanned} dead letters; the stream holds more. Counts and
        actions cover only these {@inventory.scanned}; reload after acting to inspect the rest.
      </p>

      <div id="dead-letters-groups" class="sr-ui-table-shell">
        <table class={ui_table_class(size: "sm")}>
          <thead>
            <tr class="text-xs uppercase tracking-wide text-sr-muted">
              <th>Contract</th>
              <th>Reason</th>
              <th>Records</th>
              <th>Agents</th>
              <th>Dead-lettered</th>
              <th>Detail</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={{group, index} <- Enum.with_index(@inventory.groups)}
              id={"dead-letters-group-#{index}"}
            >
              <td class="font-mono text-xs font-medium">{contract_label(group)}</td>
              <td class="font-mono text-xs">{reason_label(group)}</td>
              <td class="font-mono text-xs text-error font-semibold">{group.count}</td>
              <td class="text-xs" title={Enum.join(group.agents, ", ")}>
                {agents_label(group)}
              </td>
              <td class="font-mono text-xs text-sr-muted">
                <.user_time
                  id={"dead-letters-group-#{index}-first-stored-at"}
                  value={group.first_stored_at}
                  timezone={@timezone}
                  style={:compact}
                  fallback={group.first_stored_at || "unknown"}
                /> –
                <.user_time
                  id={"dead-letters-group-#{index}-last-stored-at"}
                  value={group.last_stored_at}
                  timezone={@timezone}
                  style={:compact}
                  fallback={group.last_stored_at || "unknown"}
                />
              </td>
              <td class="max-w-sm text-xs break-words">{group.reason_detail}</td>
              <td class="whitespace-nowrap text-right">
                <.ui_button
                  type="button"
                  size="xs"
                  variant="neutral"
                  phx-click="confirm"
                  phx-value-action="replay"
                  phx-value-group={index}
                  phx-target={@target}
                  disabled={@busy}
                >
                  Replay
                </.ui_button>
                <.ui_button
                  type="button"
                  size="xs"
                  variant="danger"
                  phx-click="confirm"
                  phx-value-action="purge"
                  phx-value-group={index}
                  phx-target={@target}
                  disabled={@busy}
                >
                  Purge
                </.ui_button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="flex justify-end">
        <.ui_button
          id="dead-letters-purge-all"
          type="button"
          size="xs"
          variant="danger"
          phx-click="confirm"
          phx-value-action="purge"
          phx-value-group="all"
          phx-target={@target}
          disabled={@busy}
        >
          Purge all
        </.ui_button>
      </div>
    </div>
    """
  end

  attr(:result, :any, required: true)

  defp action_result(%{result: {_running, {:ok, summary}}} = assigns) do
    assigns = assign(assigns, :summary, summary)

    ~H"""
    <div id="dead-letters-result" class="mb-3 rounded border border-success/40 px-3 py-2 text-xs">
      {action_past(@summary.action)} {@summary.done}.
      <span :if={@summary.kept > 0}>
        {@summary.kept} replayed but their dead-letter copy could not be deleted.
      </span>
      <span :if={@summary.failed > 0} class="text-error">
        {@summary.failed} failed and are still held: {Enum.join(@summary.errors, "; ")}.
      </span>
      <span :if={@summary.error} class="text-error">
        It stopped early after a failure: {inspect(@summary.error)}. Reload to see what remains held.
      </span>
      <span :if={not @summary.complete and is_nil(@summary.error)}>
        More matched than one run handles; run it again.
      </span>
    </div>
    """
  end

  defp action_result(%{result: {_running, {:error, reason}}} = assigns) do
    assigns = assign(assigns, :message, action_error(reason))

    ~H"""
    <div
      id="dead-letters-result"
      class="mb-3 rounded border border-error/40 px-3 py-2 text-xs text-error"
    >
      {@message}
    </div>
    """
  end

  defp action_error({:badrpc, :timeout}),
    do:
      "The call to the cluster coordinator timed out. Work it had already started may still be " <>
        "running; reload to see what remains held."

  defp action_error({:badrpc, reason}),
    do:
      "The call to the cluster coordinator failed (#{inspect(reason)}). Some records may already " <>
        "have been handled; reload to see what remains held."

  defp action_error(:no_coordinator), do: "The action did not run: no cluster coordinator is reachable."
  defp action_error(reason), do: "The action did not run: #{inspect(reason)}"

  defp contract_label(%{contract: nil}), do: "unattributed"
  defp contract_label(%{contract: contract}), do: contract

  defp reason_label(%{reason: nil}), do: "no reason"
  defp reason_label(%{reason: reason}), do: reason

  defp action_verb(:replay), do: "Replaying"
  defp action_verb(:purge), do: "Purging"

  defp action_past(:replay), do: "Replayed"
  defp action_past(:purge), do: "Purged"

  defp confirm_title(%{action: :replay}), do: "Replay dead letters"
  defp confirm_title(%{action: :purge}), do: "Purge dead letters"

  defp inventory_error({:error, :no_coordinator}), do: "no cluster coordinator is reachable"

  defp inventory_error({:error, {:badrpc, :timeout}}),
    do:
      "the call to the cluster coordinator timed out. A read it had already started may still be " <>
        "running; wait before inspecting again."

  defp inventory_error({:error, reason}), do: inspect(reason)

  defp agents_label(%{agents: [], agent_count: 0}), do: "unknown"
  defp agents_label(%{agents: [one], agent_count: 1}), do: one
  defp agents_label(%{agents: [first | _], agent_count: count}), do: "#{first} +#{count - 1}"
end
