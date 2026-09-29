defmodule ServiceRadarWebNGWeb.DashboardPackageLive.ActionConfirmation do
  @moduledoc """
  The host side of dashboard action confirmation.

  The dashboard's frame channel asks this LiveView to confirm an action that
  requires it (`{:dashboard_action_confirmation_request, request}`). The dialog
  is rendered by the LiveView, outside the dashboard renderer's element, and the
  operator's answer goes straight back to the channel process with the binding
  the dialog displayed. The renderer never sees the request or the answer, only
  the outcome of its pending invoke.

  Requests queue; the dialog shows the oldest one. Only the viewer the request
  was issued for can see or answer it.

  Limitation: a browser-module renderer runs in the page's own JavaScript realm,
  so it is not isolated from the host DOM. This dialog stops a package from
  dispatching a confirmation-required action through the dashboard API alone;
  it cannot stop package code that scripts the host page itself.
  """

  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1, user_time: 1]
  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNG.Northbound.ActionForm

  @max_queued 8

  def assign_defaults(socket), do: assign(socket, :action_confirmations, [])

  @doc "Queues a request from the frame channel for the current viewer."
  def handle_request(socket, %{id: id, channel_pid: pid, user_id: user_id} = request) when is_pid(pid) do
    queue = socket.assigns[:action_confirmations] || []

    cond do
      user_id != current_user_id(socket) ->
        socket

      Enum.any?(queue, &(&1.id == id)) ->
        socket

      length(queue) >= @max_queued ->
        reply(request, :declined, socket)
        socket

      true ->
        assign(socket, :action_confirmations, queue ++ [request])
    end
  end

  def handle_request(socket, _request), do: socket

  @doc """
  Answers the displayed request. Only the request at the head of the queue is
  visible, so only it can be confirmed; a decline may name any queued request.
  """
  def handle_decision(socket, :confirmed, id) do
    case socket.assigns[:action_confirmations] || [] do
      [%{id: ^id} = request | rest] ->
        reply(request, :confirmed, socket)
        assign(socket, :action_confirmations, rest)

      _other ->
        socket
    end
  end

  def handle_decision(socket, :declined, id) do
    queue = socket.assigns[:action_confirmations] || []
    id = id || head_id(queue)

    case Enum.split_with(queue, &(&1.id == id)) do
      {[request | _], rest} ->
        reply(request, :declined, socket)
        assign(socket, :action_confirmations, rest)

      {[], _queue} ->
        socket
    end
  end

  @doc "Drops a request the channel expired or abandoned."
  def handle_closed(socket, id) do
    queue = socket.assigns[:action_confirmations] || []
    assign(socket, :action_confirmations, Enum.reject(queue, &(&1.id == id)))
  end

  defp reply(request, decision, socket) do
    send(
      request.channel_pid,
      {:dashboard_action_confirmation_reply, request.id, decision,
       %{user_id: current_user_id(socket), binding: request.binding}}
    )
  end

  defp head_id([%{id: id} | _]), do: id
  defp head_id(_queue), do: nil

  defp current_user_id(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{id: id}} when not is_nil(id) -> to_string(id)
      _other -> nil
    end
  end

  attr :confirmations, :list, required: true
  attr :timezone, :string, default: "Etc/UTC"

  def confirmation_modal(assigns) do
    assigns =
      assigns
      |> assign(:request, List.first(assigns.confirmations))
      |> assign(:queued, max(length(assigns.confirmations) - 1, 0))

    ~H"""
    <.ui_modal
      :if={@request}
      id="dashboard-action-confirmation"
      size="md"
      on_cancel="decline_dashboard_action"
      show_close={true}
    >
      <div class="flex items-start gap-3">
        <div class="rounded-lg bg-warning/12 p-2">
          <.icon name="hero-shield-exclamation" class="size-5 text-warning" />
        </div>
        <div class="min-w-0 flex-1">
          <h3 class="text-lg font-semibold text-sr-ink">Confirm action</h3>
          <p class="text-sm text-sr-muted">
            A dashboard is asking to run this action as you. ServiceRadar, not the dashboard, is asking you to confirm it.
          </p>
        </div>
      </div>

      <div class="mt-4 rounded-lg border border-sr-line bg-sr-subtle/60 p-3">
        <div class="font-medium text-sr-ink" id="dashboard-action-confirmation-label">
          {@request.label}
        </div>
        <div class="mt-2 flex flex-wrap items-center gap-2 text-xs">
          <.ui_badge :if={ActionForm.present_text?(@request.provider_name)} size="sm" variant="ghost">
            {@request.provider_name}
          </.ui_badge>
          <.ui_badge
            size="sm"
            variant={ActionForm.safety_badge_variant(@request.safety_classification)}
            id="dashboard-action-confirmation-safety"
          >
            {ActionForm.humanize(@request.safety_classification || "unclassified")}
          </.ui_badge>
          <.ui_badge :if={ActionForm.present_text?(@request.route_slug)} size="sm" variant="outline">
            Dashboard {@request.route_slug}
          </.ui_badge>
        </div>
        <p :if={ActionForm.present_text?(@request.description)} class="mt-2 text-sm text-sr-muted">
          {@request.description}
        </p>
      </div>

      <div class="mt-4">
        <div class="text-sm font-medium text-sr-ink">
          {length(@request.targets)} {if @request.target_scope == "interface",
            do: "interface target(s)",
            else: "device target(s)"}
        </div>
        <ul
          id="dashboard-action-confirmation-targets"
          class="mt-2 max-h-48 space-y-1 overflow-y-auto rounded-lg border border-sr-line p-2 font-mono text-xs"
        >
          <li :for={target <- @request.targets} class="truncate">
            {target.device_uid}<span :if={ActionForm.present_text?(target.interface_uid)}> / {target.interface_uid}</span>
          </li>
        </ul>
      </div>

      <div :if={@request.inputs != []} class="mt-4">
        <div class="text-sm font-medium text-sr-ink">Input</div>
        <dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs">
          <%= for {name, value} <- @request.inputs do %>
            <dt class="text-sr-muted">{ActionForm.humanize(name)}</dt>
            <dd class="truncate font-mono text-sr-ink">{input_value(value)}</dd>
          <% end %>
        </dl>
      </div>

      <div class="mt-4 flex flex-wrap items-center justify-between gap-2 text-xs text-sr-muted">
        <span>
          Expires
          <.user_time
            id="dashboard-action-confirmation-expires"
            value={@request.expires_at}
            timezone={@timezone}
            style={:compact}
          />
        </span>
        <span :if={@queued > 0}>{@queued} more waiting</span>
      </div>

      <div class="flex justify-end gap-2 pt-4">
        <.ui_button
          type="button"
          id="dashboard-action-confirmation-decline"
          phx-click="decline_dashboard_action"
          phx-value-id={@request.id}
          size="sm"
          variant="ghost"
        >
          Decline
        </.ui_button>
        <.ui_button
          type="button"
          id="dashboard-action-confirmation-confirm"
          phx-click="confirm_dashboard_action"
          phx-value-id={@request.id}
          size="sm"
          variant={if @request.safety_classification == "destructive", do: "danger", else: "primary"}
        >
          <.icon name="hero-play" class="size-4" /> Run action
        </.ui_button>
      </div>
    </.ui_modal>
    """
  end

  defp input_value(:redacted), do: "(hidden)"
  defp input_value(nil), do: "—"
  defp input_value(value) when is_binary(value), do: String.slice(value, 0, 120)
  defp input_value(value) when is_boolean(value), do: if(value, do: "Yes", else: "No")
  defp input_value(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp input_value(value), do: value |> Jason.encode!() |> String.slice(0, 120)
end
