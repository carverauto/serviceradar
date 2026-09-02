defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.Index do
  @moduledoc """
  `/settings/notifications` - the operator surface of the notification platform.

  Five tabs, one LiveView, one catalog entry: Channels, Routes and Escalation,
  Silences, Providers, and Delivery Log. The active tab is a nested path segment
  (`/settings/notifications/deliveries`) driven through `handle_params/3` and
  `push_patch/2`, so a tab is deep-linkable, survives a reload, and is shareable;
  the Delivery Log's filters ride in the query string for the same reason - "here
  is why you were not paged" should be a link.

  ## Authorization

  Every `handle_event/3` goes through one gate. The `handle_event/3` clause below
  authorizes the event name against the socket scope with
  `ServiceRadarWebNGWeb.Settings.NotificationsLive.Access` and only then
  dispatches to a handler. Nothing reaches a side effect first. That is stronger
  than a check at the top of each clause, which is only as good as the next
  person's memory, and it is why a forged `save_channel` from a client that never
  rendered the control changes nothing.

  The scope comes from the authenticated session on the socket. No handler reads
  a scope, user id, or permission list out of event parameters, and no
  server-derived field - `partition_id`, `created_by_user_id` - is accepted from
  a form: `partition_id` is bound server-side by the resource's own change, and
  the silence creator is taken from `socket.assigns.current_scope`.

  ## Lifecycle

  The disconnected mount issues no query. It assigns a loading state and empty
  streams; the data loads on the connected `handle_params/3`. Every list is a
  LiveView stream with a server-side bound, and the Delivery Log - the one
  genuinely unbounded table - is bounded to
  `ServiceRadarWebNGWeb.Settings.NotificationsLive.Data.delivery_limit/0` rows per
  window rather than being paged into assigns.

  PubSub is subscribed only when `connected?/1` is true and only for a viewer who
  may read deliveries, and `handle_info/2` re-checks that permission before it
  touches the stream, so a permission revoked mid-session cannot keep pushing
  rows at a socket that may no longer read them.

  ## Nothing here re-decides anything

  Routing, suppression, escalation, retry, failover, and rendering belong to
  `ServiceRadar.Notifications`. This module reads, previews with the engine's own
  `Router` and `MatchExpression.Evaluator`, writes through the Ash actions, and
  renders. The one piece of behaviour it adds is the edge-route safety warning,
  which is a statement about configuration rather than a dispatch decision.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Notifications.Declarative.Definition
  alias ServiceRadar.Notifications.MatchExpression.Evaluator
  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationEscalationPolicy
  alias ServiceRadar.Notifications.NotificationEscalationStep
  alias ServiceRadar.Notifications.NotificationEscalationStepChannel
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.NotificationRoute
  alias ServiceRadar.Notifications.NotificationSilence
  alias ServiceRadar.Notifications.Router, as: NotificationRouter
  alias ServiceRadar.OutboundMail
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Access
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Components
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Contracts
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Data
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.DeliveryFilters
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.EdgeRouteSafety
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Predicate
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Presentation
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.ProviderUpload
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.ProviderVersions
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.TestSend
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  @deliveries_topic "notifications:deliveries"
  @preview_alert_limit 200
  @preview_sample 5

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    case mount_scope(socket, scope) do
      {:ok, current_scope} ->
        {:ok, initial_assigns(socket, current_scope)}

      {:error, :permission_revoked} ->
        {:ok,
         socket
         |> put_flash(:error, "Not authorized to view notification settings")
         |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  # The disconnected render must stay query-free. The connected mount may and
  # must refresh authority before it subscribes to delivery PubSub.
  defp mount_scope(socket, scope) do
    if connected?(socket) do
      Access.authorize_current_access(scope)
    else
      if Access.any_access?(scope),
        do: {:ok, scope},
        else: {:error, :permission_revoked}
    end
  end

  defp initial_assigns(socket, scope) do
    if connected?(socket) and RBAC.can?(scope, Access.deliveries_view()) do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, @deliveries_topic)
    end

    socket
    |> assign(:page_title, "Notifications")
    |> assign(:current_path, "/settings/notifications")
    |> assign(:tab, nil)
    |> assign(:loading, true)
    |> assign_authority(scope)
    |> assign(:channel_index, %{})
    |> assign(:providers, [])
    |> assign(:policies, [])
    |> assign(:schedules, [])
    |> assign(:policy_warnings, %{})
    |> assign(:suppression, nil)
    |> assign(:silence_counts, %{})
    |> assign(:filters, DeliveryFilters.empty())
    |> assign(:channel_form, nil)
    |> assign(:provider_upload, nil)
    |> assign(:provider_versions, nil)
    |> assign(:route_form, nil)
    |> assign(:policy_form, nil)
    |> assign(:silence_form, nil)
    |> assign(:test_result, nil)
    |> assign(:preview, nil)
    |> assign(:selected_delivery, nil)
    |> assign(:confirmation, nil)
    |> stream(:channels, [])
    |> stream(:routes, [])
    |> stream(:silences, [])
    |> stream(:providers, [])
    |> stream(:deliveries, [])
  end

  # --- params ---------------------------------------------------------------

  @impl true
  def handle_params(params, _uri, socket) do
    case refresh_scope_for_params(socket) do
      {:ok, socket} ->
        handle_authorized_params(params, socket)

      {:error, :permission_revoked} ->
        {:noreply,
         socket
         |> put_flash(:error, "Not authorized to view notification settings")
         |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  defp handle_authorized_params(params, socket) do
    scope = socket.assigns.current_scope

    case resolve_tab(scope, params["tab"]) do
      {:ok, tab} ->
        {:noreply, socket |> assign_tab(tab, params) |> load_tab(tab)}

      {:fallback, tab, message} ->
        # The requested tab is not this scope's to see - or does not exist - so
        # the permitted tab is rendered instead and the URL is corrected. The
        # forbidden tab's data is never loaded, so nothing about it reaches the
        # client even for the instant before the patch lands.
        socket =
          socket
          |> maybe_flash(message)
          |> assign_tab(tab, params)
          |> load_tab(tab)

        {:noreply, patch_to_tab(socket, tab)}

      :none ->
        {:noreply,
         socket
         |> put_flash(:error, "Not authorized to view notification settings")
         |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  # The disconnected mount deliberately performs no database work. Once the
  # socket is connected, refresh authority before any tab query is issued.
  defp refresh_scope_for_params(socket) do
    if connected?(socket) do
      case Access.authorize_current_access(socket.assigns.current_scope) do
        {:ok, current_scope} -> {:ok, assign_authority(socket, current_scope)}
        _denied -> {:error, :permission_revoked}
      end
    else
      {:ok, socket}
    end
  end

  defp assign_authority(socket, scope) do
    socket
    |> assign(:current_scope, scope)
    |> assign(:visible_tabs, Access.visible_tabs(scope))
    |> assign(:can_manage_channels, RBAC.can?(scope, Access.channels_manage()))
    |> assign(:can_test_send, RBAC.can?(scope, Access.test_send()))
    |> assign(:can_manage_routes, RBAC.can?(scope, Access.routes_manage()))
    |> assign(:can_manage_silences, RBAC.can?(scope, Access.silences_manage()))
    |> assign(:can_manage_providers, RBAC.can?(scope, Access.providers_manage()))
  end

  defp assign_tab(socket, tab, params) do
    socket
    |> assign(:tab, tab)
    |> assign(:current_path, "/settings/notifications/#{tab.id}")
    |> assign(:filters, DeliveryFilters.parse(params))
  end

  # Patch only over a live socket. A disconnected render has no navigation to
  # annotate; it simply renders the permitted tab, and the URL is corrected the
  # moment the socket connects.
  defp patch_to_tab(socket, tab) do
    if connected?(socket) do
      push_patch(socket, to: ~p"/settings/notifications/#{tab.id}")
    else
      socket
    end
  end

  # A tab segment is operator-supplied text. It is resolved through the
  # whitelist, never cast into an atom, and a tab the scope may not see falls
  # back to a permitted one rather than rendering a half-populated page.
  defp resolve_tab(scope, nil) do
    # No segment: land on the first permitted tab and correct the URL so it
    # names the tab it is showing. No flash - nothing went wrong.
    case Access.default_tab(scope) do
      nil -> :none
      tab -> {:fallback, tab, nil}
    end
  end

  defp resolve_tab(scope, requested) do
    with {:ok, tab} <- Access.tab(requested),
         true <- Access.visible_tab?(scope, tab) do
      {:ok, tab}
    else
      :error -> fallback(scope, "That notification tab does not exist.")
      false -> fallback(scope, "You do not have access to that notification tab.")
    end
  end

  defp maybe_flash(socket, nil), do: socket
  defp maybe_flash(socket, message), do: put_flash(socket, :error, message)

  defp fallback(scope, message) do
    case Access.default_tab(scope) do
      nil -> :none
      tab -> {:fallback, tab, message}
    end
  end

  # --- loading --------------------------------------------------------------

  defp load_tab(socket, tab) do
    if connected?(socket) do
      socket
      |> assign(:loading, false)
      |> do_load_tab(tab.id)
    else
      assign(socket, :loading, true)
    end
  end

  defp do_load_tab(socket, "channels") do
    scope = socket.assigns.current_scope
    channels = Data.list_channels(scope)

    socket
    |> assign(:channel_index, trim_index(channels))
    |> assign(:providers, active_providers(scope))
    |> stream(:channels, channels, reset: true)
  end

  defp do_load_tab(socket, "routes") do
    scope = socket.assigns.current_scope
    routes = Data.list_routes(scope)
    policies = Data.list_policies(scope)
    index = channel_index_for(scope)

    socket
    |> assign(:channel_index, index)
    |> assign(:policies, policies)
    |> assign(:schedules, Data.list_schedules(scope))
    |> assign(:policy_warnings, policy_warnings(policies, index))
    |> stream(:routes, routes, reset: true)
  end

  defp do_load_tab(socket, "silences") do
    scope = socket.assigns.current_scope
    silences = Data.list_silences(scope)
    summary = Data.suppression_summary(scope, DateTime.add(DateTime.utc_now(), -7 * 86_400))

    socket
    |> assign(:suppression, summary)
    |> assign(:silence_counts, summary.silences)
    |> stream(:silences, silences, reset: true)
  end

  defp do_load_tab(socket, "providers") do
    scope = socket.assigns.current_scope

    socket
    |> assign(:channel_index, channel_index_for(scope))
    |> stream(:providers, Data.list_providers(scope), reset: true)
  end

  defp do_load_tab(socket, "deliveries") do
    scope = socket.assigns.current_scope
    deliveries = Data.list_deliveries(scope, socket.assigns.filters, DateTime.utc_now())

    socket
    |> assign(:channel_index, channel_index_for(scope))
    |> stream(:deliveries, deliveries, reset: true)
  end

  defp do_load_tab(socket, _tab), do: socket

  defp channel_index_for(scope) do
    if RBAC.can?(scope, Access.channels_view()) do
      scope |> Data.list_channels() |> trim_index()
    else
      %{}
    end
  end

  # A trimmed index rather than the full records: the escalation editor, the
  # failover picker, and the edge-route warning need identity and route, not the
  # provider configuration of every channel held in socket memory.
  defp trim_index(channels) do
    Map.new(channels, fn channel ->
      {to_string(channel.id),
       %{
         id: channel.id,
         name: channel.name,
         enabled: channel.enabled,
         execution_route: channel.execution_route,
         partition_id: channel.partition_id,
         agent_uid: channel.agent_uid,
         fail_closed: channel.fail_closed,
         fallback_channel_id: channel.fallback_channel_id
       }}
    end)
  end

  defp active_providers(scope) do
    scope
    |> Data.list_providers()
    |> Enum.filter(&(&1.status == :active))
  end

  defp policy_warnings(policies, index) do
    policies
    |> Enum.flat_map(fn policy ->
      case EdgeRouteSafety.evaluate(policy_channel_sets(policy), index) do
        nil -> []
        warning -> [{to_string(policy.id), warning}]
      end
    end)
    |> Map.new()
  end

  defp policy_channel_sets(%{steps: steps}) when is_list(steps) do
    Enum.map(steps, fn step ->
      step
      |> Map.get(:step_channels, [])
      |> List.wrap()
      |> Enum.map(&to_string(&1.channel_id))
    end)
  end

  defp policy_channel_sets(_policy), do: []

  # --- the single authorization gate ----------------------------------------

  @impl true
  def handle_event(event, params, socket) do
    case Access.authorize_event(socket.assigns.current_scope, event) do
      {:ok, current_scope} ->
        socket
        |> assign_authority(current_scope)
        |> then(&handle_authorized(event, params, &1))

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not authorized to perform that action.")}

      {:error, :unknown_event} ->
        {:noreply, socket}
    end
  end

  # --- channels -------------------------------------------------------------

  defp handle_authorized("new_channel", _params, socket) do
    {:noreply,
     socket
     |> assign(:channel_form, blank_channel_form(socket.assigns.providers))
     |> assign(:test_result, nil)}
  end

  defp handle_authorized("edit_channel", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case fetch_channel(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That channel is not available.")}

      channel ->
        {:noreply,
         socket
         |> assign(:channel_form, channel_form(channel, socket.assigns.providers))
         |> assign(:test_result, nil)}
    end
  end

  defp handle_authorized("cancel_channel_form", _params, socket) do
    {:noreply, socket |> assign(:channel_form, nil) |> assign(:test_result, nil)}
  end

  defp handle_authorized("validate_channel", %{"channel" => params} = raw, socket) do
    form = merge_channel_form(socket.assigns.channel_form, params, raw["config"], socket)
    {:noreply, assign(socket, :channel_form, form)}
  end

  defp handle_authorized("save_channel", %{"channel" => params} = raw, socket) do
    scope = socket.assigns.current_scope
    form = merge_channel_form(socket.assigns.channel_form, params, raw["config"], socket)
    {config, secret_refs} = split_config(form)

    attrs =
      put_if(
        %{
          name: blank_to_nil(params["name"]),
          description: blank_to_nil(params["description"]),
          execution_route: blank_to_nil(params["execution_route"]),
          agent_uid: blank_to_nil(params["agent_uid"]),
          fallback_channel_id: blank_to_nil(params["fallback_channel_id"]),
          fail_closed: truthy?(params["fail_closed"]),
          rate_limit_per_minute: integer_or_nil(params["rate_limit_per_minute"]),
          config: config,
          secret_refs: secret_refs
        },
        :max_attempts,
        integer_or_nil(params["max_attempts"])
      )

    case save_channel(scope, form, attrs, params["provider_id"]) do
      {:ok, _channel} ->
        {:noreply,
         socket
         |> put_flash(:info, "Channel saved")
         |> assign(:channel_form, nil)
         |> assign(:test_result, nil)
         |> do_load_tab("channels")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save the channel: #{error_message(reason)}")}
    end
  end

  defp handle_authorized("confirm_disable_channel", %{"id" => id}, socket) do
    case Map.get(socket.assigns.channel_index, to_string(id)) do
      nil ->
        {:noreply, socket}

      channel ->
        {:noreply,
         assign(socket, :confirmation, %{
           title: "Disable #{channel.name}?",
           message:
             "The channel stops delivering and its delivery history is preserved. Routing to it will record deliveries with suppression reason channel disabled rather than dropping them silently.",
           event: "disable_channel",
           confirm_label: "Disable channel",
           id: to_string(id),
           items: []
         })}
    end
  end

  defp handle_authorized("disable_channel", %{"id" => id}, socket) do
    toggle_channel(socket, id, :disable, "Channel disabled")
  end

  defp handle_authorized("enable_channel", %{"id" => id}, socket) do
    toggle_channel(socket, id, :enable, "Channel enabled")
  end

  defp handle_authorized("dismiss_confirmation", _params, socket) do
    {:noreply, assign(socket, :confirmation, nil)}
  end

  defp handle_authorized("test_channel", _params, socket) do
    case socket.assigns.channel_form do
      nil ->
        {:noreply, socket}

      form ->
        {config, secrets} = test_payload(form)

        result =
          case TestSend.run(form[:provider], config, secrets) do
            {:ok, outcome} -> outcome
            {:error, outcome} -> outcome
          end

        {:noreply, assign(socket, :test_result, result)}
    end
  end

  # --- routes ---------------------------------------------------------------

  defp handle_authorized("new_route", _params, socket) do
    {:noreply, assign(socket, :route_form, blank_route_form())}
  end

  defp handle_authorized("edit_route", %{"id" => id}, socket) do
    case fetch_route(socket.assigns.current_scope, id) do
      nil -> {:noreply, put_flash(socket, :error, "That route is not available.")}
      route -> {:noreply, assign(socket, :route_form, route_form(route))}
    end
  end

  defp handle_authorized("cancel_route_form", _params, socket) do
    {:noreply, socket |> assign(:route_form, nil) |> assign(:preview, nil)}
  end

  defp handle_authorized("validate_route", %{"route" => params}, socket) do
    {:noreply, assign(socket, :route_form, merge_route_form(socket.assigns.route_form, params))}
  end

  defp handle_authorized("save_route", %{"route" => params}, socket) do
    form = merge_route_form(socket.assigns.route_form, params)

    case Predicate.to_document(form.params["combinator"], form.rows) do
      {:ok, document} ->
        attrs = route_attrs(form.params, document)

        case save_route(socket.assigns.current_scope, form, attrs) do
          {:ok, _route} ->
            {:noreply,
             socket
             |> put_flash(:info, "Route saved")
             |> assign(:route_form, nil)
             |> do_load_tab("routes")}

          {:error, reason} ->
            {:noreply, assign(socket, :route_form, Map.put(form, :error, error_message(reason)))}
        end

      {:error, reason} ->
        {:noreply, assign(socket, :route_form, Map.put(form, :error, predicate_error(reason)))}
    end
  end

  defp handle_authorized("toggle_route", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with route when not is_nil(route) <- fetch_route(scope, id),
         action = if(route.enabled, do: :disable, else: :enable),
         {:ok, _updated} <-
           route |> Ash.Changeset.for_update(action, %{}, scope: scope) |> Ash.update() do
      {:noreply, socket |> put_flash(:info, "Route updated") |> do_load_tab("routes")}
    else
      nil -> {:noreply, put_flash(socket, :error, "That route is not available.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp handle_authorized("move_route", %{"id" => id, "direction" => direction}, socket)
       when direction in ["up", "down"] do
    scope = socket.assigns.current_scope
    step = if direction == "up", do: -10, else: 10

    with route when not is_nil(route) <- fetch_route(scope, id),
         priority = max(route.priority + step, 0),
         {:ok, _updated} <-
           route
           |> Ash.Changeset.for_update(:update, %{priority: priority}, scope: scope)
           |> Ash.update() do
      {:noreply, do_load_tab(socket, "routes")}
    else
      nil -> {:noreply, put_flash(socket, :error, "That route is not available.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp handle_authorized("move_route", _params, socket), do: {:noreply, socket}

  defp handle_authorized("add_predicate_row", _params, socket) do
    {:noreply, update_rows(socket, &(&1 ++ [Predicate.blank_row()]))}
  end

  defp handle_authorized("remove_predicate_row", %{"index" => index}, socket) do
    position = integer_or_nil(index)

    {:noreply,
     update_rows(socket, fn rows ->
       if is_nil(position), do: rows, else: List.delete_at(rows, position)
     end)}
  end

  defp handle_authorized("preview_routing", _params, socket) do
    {:noreply, assign(socket, :preview, routing_preview(socket))}
  end

  # --- escalation policies ---------------------------------------------------

  defp handle_authorized("new_policy", _params, socket) do
    {:noreply, assign(socket, :policy_form, blank_policy_form())}
  end

  defp handle_authorized("edit_policy", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.policies, &(to_string(&1.id) == to_string(id))) do
      nil -> {:noreply, put_flash(socket, :error, "That policy is not available.")}
      policy -> {:noreply, assign(socket, :policy_form, policy_form(policy))}
    end
  end

  defp handle_authorized("cancel_policy_form", _params, socket) do
    {:noreply, assign(socket, :policy_form, nil)}
  end

  defp handle_authorized("validate_policy", %{"policy" => params}, socket) do
    form = merge_policy_form(socket.assigns.policy_form, params)

    {:noreply, assign(socket, :policy_form, with_policy_warning(form, socket.assigns.channel_index))}
  end

  defp handle_authorized("save_policy", %{"policy" => params}, socket) do
    form = merge_policy_form(socket.assigns.policy_form, params)

    cond do
      form.steps == [] ->
        {:noreply, assign(socket, :policy_form, Map.put(form, :error, "A policy needs at least one step."))}

      Enum.any?(form.steps, &((&1["channel_ids"] || []) == [])) ->
        {:noreply,
         assign(
           socket,
           :policy_form,
           Map.put(form, :error, "Step #{empty_step_number(form.steps)} names no channel.")
         )}

      true ->
        save_policy_and_steps(socket, form)
    end
  end

  defp handle_authorized("add_step", _params, socket) do
    {:noreply, update_steps(socket, &(&1 ++ [blank_step(length(&1))]))}
  end

  defp handle_authorized("remove_step", %{"index" => index}, socket) do
    position = integer_or_nil(index)

    {:noreply,
     update_steps(socket, fn steps ->
       if is_nil(position), do: steps, else: List.delete_at(steps, position)
     end)}
  end

  defp handle_authorized("move_step", %{"index" => index, "direction" => direction}, socket)
       when direction in ["up", "down"] do
    position = integer_or_nil(index)
    {:noreply, update_steps(socket, &move(&1, position, direction))}
  end

  defp handle_authorized("move_step", _params, socket), do: {:noreply, socket}

  # --- silences --------------------------------------------------------------

  defp handle_authorized("new_silence", _params, socket) do
    {:noreply, assign(socket, :silence_form, blank_silence_form())}
  end

  defp handle_authorized("edit_silence", %{"id" => id}, socket) do
    case fetch_silence(socket.assigns.current_scope, id) do
      nil -> {:noreply, put_flash(socket, :error, "That silence is not available.")}
      silence -> {:noreply, assign(socket, :silence_form, silence_form(silence))}
    end
  end

  defp handle_authorized("cancel_silence_form", _params, socket) do
    {:noreply, assign(socket, :silence_form, nil)}
  end

  defp handle_authorized("validate_silence", %{"silence" => params}, socket) do
    form = merge_silence_form(socket.assigns.silence_form, params)

    {:noreply, assign(socket, :silence_form, with_blast_radius(form, socket.assigns.current_scope))}
  end

  defp handle_authorized("save_silence", %{"silence" => params}, socket) do
    form = merge_silence_form(socket.assigns.silence_form, params)

    with {:ok, matchers} <- Predicate.to_document(form.params["combinator"], form.rows),
         {:ok, attrs} <- silence_attrs(form.params, matchers, socket.assigns.current_scope),
         {:ok, _silence} <- save_silence(socket.assigns.current_scope, form, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, "Silence saved")
       |> assign(:silence_form, nil)
       |> do_load_tab("silences")}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :silence_form, Map.put(form, :error, silence_error(reason)))}
    end
  end

  defp handle_authorized("confirm_cancel_silence", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :confirmation, %{
       title: "Cancel this silence?",
       message:
         "Suppression stops on the next dispatch evaluation. The silence stays listed as cancelled so the audit trail survives.",
       event: "cancel_silence",
       confirm_label: "Cancel silence",
       id: to_string(id),
       items: []
     })}
  end

  defp handle_authorized("cancel_silence", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with silence when not is_nil(silence) <- fetch_silence(scope, id),
         {:ok, _cancelled} <-
           silence |> Ash.Changeset.for_update(:cancel, %{}, scope: scope) |> Ash.update() do
      {:noreply,
       socket
       |> put_flash(:info, "Silence cancelled")
       |> assign(:confirmation, nil)
       |> do_load_tab("silences")}
    else
      nil ->
        {:noreply, socket |> assign(:confirmation, nil) |> put_flash(:error, "Silence unavailable.")}

      {:error, reason} ->
        {:noreply, socket |> assign(:confirmation, nil) |> put_flash(:error, error_message(reason))}
    end
  end

  # --- providers -------------------------------------------------------------

  defp handle_authorized("confirm_disable_provider", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    affected = channels_for_provider(scope, id)

    {:noreply,
     assign(socket, :confirmation, %{
       title: "Disable this provider?",
       message:
         "These channels become unusable and their deliveries will be recorded with suppression reason channel disabled:",
       event: "disable_provider",
       confirm_label: "Disable provider",
       id: to_string(id),
       items: Enum.map(affected, & &1.name)
     })}
  end

  defp handle_authorized("disable_provider", %{"id" => id}, socket) do
    toggle_provider(socket, id, :disable, "Provider disabled")
  end

  defp handle_authorized("enable_provider", %{"id" => id}, socket) do
    toggle_provider(socket, id, :activate, "Provider activated")
  end

  # --- declarative provider upload and versioning ----------------------------

  defp handle_authorized("new_provider_upload", _params, socket) do
    {:noreply,
     socket
     |> assign(:provider_upload, ProviderUpload.blank_form())
     |> assign(:provider_versions, nil)}
  end

  defp handle_authorized("replace_provider_definition", %{"id" => id}, socket) do
    with_declarative_provider(socket, id, fn provider ->
      {:noreply, assign(socket, :provider_upload, ProviderUpload.form_for(provider))}
    end)
  end

  defp handle_authorized("cancel_provider_upload", _params, socket) do
    {:noreply, assign(socket, :provider_upload, nil)}
  end

  defp handle_authorized("validate_provider_upload", %{"provider" => params}, socket) do
    {:noreply, assign(socket, :provider_upload, upload_form(socket, params))}
  end

  defp handle_authorized("save_provider_upload", %{"provider" => params}, socket) do
    form = upload_form(socket, params)

    case form.definition do
      nil -> {:noreply, assign(socket, :provider_upload, nothing_to_save(form))}
      definition -> save_definition(socket, form, definition)
    end
  end

  defp handle_authorized("show_provider_versions", %{"id" => id}, socket) do
    with_declarative_provider(socket, id, fn provider ->
      {:noreply, assign(socket, :provider_versions, version_panel(socket, provider))}
    end)
  end

  defp handle_authorized("close_provider_versions", _params, socket) do
    {:noreply, assign(socket, :provider_versions, nil)}
  end

  defp handle_authorized("confirm_rollback_provider", %{"id" => id, "version" => version}, socket) do
    with_declarative_provider(socket, id, fn provider ->
      panel = version_panel(socket, provider)

      case ProviderVersions.find(panel.entries, integer_or_nil(version)) do
        nil ->
          {:noreply, put_flash(socket, :error, "That provider version is not available.")}

        entry ->
          {:noreply,
           socket
           |> assign(:provider_versions, panel)
           |> assign(:confirmation, rollback_confirmation(provider, entry, panel.channels))}
      end
    end)
  end

  defp handle_authorized("rollback_provider", %{"id" => id, "version" => version}, socket) do
    with_declarative_provider(socket, id, fn provider ->
      roll_back(socket, provider, integer_or_nil(version))
    end)
  end

  # --- delivery log ----------------------------------------------------------

  defp handle_authorized("filter_deliveries", params, socket) do
    query = params |> DeliveryFilters.parse() |> DeliveryFilters.to_params()
    {:noreply, push_patch(socket, to: deliveries_path(query))}
  end

  defp handle_authorized("clear_delivery_filters", _params, socket) do
    {:noreply, push_patch(socket, to: deliveries_path(%{}))}
  end

  defp handle_authorized("show_delivery", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Data.fetch_delivery(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That delivery is not available.")}

      delivery ->
        {:noreply,
         assign(socket, :selected_delivery, %{
           delivery: delivery,
           chain: Data.failover_chain(scope, delivery)
         })}
    end
  end

  defp handle_authorized("close_delivery", _params, socket) do
    {:noreply, assign(socket, :selected_delivery, nil)}
  end

  defp handle_authorized(_event, _params, socket), do: {:noreply, socket}

  # --- live updates ----------------------------------------------------------

  @impl true
  def handle_info({:notification_delivery, delivery}, socket) do
    # Re-checked here, not only at subscribe: a permission revoked mid-session
    # must stop the feed for this socket, and an envelope for a record the viewer
    # may not read is never rendered.
    case Access.authorize_current(socket.assigns.current_scope, Access.deliveries_view()) do
      {:ok, current_scope} ->
        socket = assign_authority(socket, current_scope)
        on_log? = match?(%{id: "deliveries"}, socket.assigns.tab)

        if on_log? do
          {:noreply, stream_insert(socket, :deliveries, delivery, at: 0)}
        else
          {:noreply, socket}
        end

      _revoked ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tabs, tab_links(assigns))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      shell={:operations}
    >
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <section class="space-y-2">
          <p class="text-sm font-medium text-sr-brand">Settings</p>
          <h1 class="text-2xl font-semibold tracking-normal">Notifications</h1>
          <p class="max-w-3xl text-sm text-sr-ink/65">
            Channels, routing, escalation, silences, providers, and the delivery audit that
            answers "why was I not paged?".
          </p>
        </section>

        <div role="tablist" aria-label="Notification settings sections">
          <.ui_tabs tabs={@tabs} />
        </div>

        <div :if={@tab}>
          <Components.channels_tab
            :if={@tab.id == "channels"}
            streams={@streams}
            can_manage={@can_manage_channels}
            can_test={@can_test_send}
            channel_form={@channel_form}
            providers={@providers}
            channel_index={@channel_index}
            test_result={@test_result}
            loading={@loading}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />

          <Components.routes_tab
            :if={@tab.id == "routes"}
            streams={@streams}
            can_manage={@can_manage_routes}
            route_form={@route_form}
            policy_form={@policy_form}
            policies={@policies}
            schedules={@schedules}
            channel_index={@channel_index}
            policy_warnings={@policy_warnings}
            preview={@preview}
            loading={@loading}
          />

          <Components.silences_tab
            :if={@tab.id == "silences"}
            streams={@streams}
            can_manage={@can_manage_silences}
            silence_form={@silence_form}
            suppression={@suppression}
            silence_counts={@silence_counts}
            loading={@loading}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />

          <Components.providers_tab
            :if={@tab.id == "providers"}
            streams={@streams}
            can_manage={@can_manage_providers}
            upload={@provider_upload}
            versions={@provider_versions}
            loading={@loading}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />

          <Components.deliveries_tab
            :if={@tab.id == "deliveries"}
            streams={@streams}
            filters={@filters}
            channel_index={@channel_index}
            selected={@selected_delivery}
            limit={Data.delivery_limit()}
            loading={@loading}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />
        </div>

        <Components.confirmation_dialog confirmation={@confirmation} />
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp tab_links(assigns) do
    active_id = assigns.tab && assigns.tab.id

    Enum.map(assigns.visible_tabs, fn tab ->
      %{
        label: tab.label,
        patch: ~p"/settings/notifications/#{tab.id}",
        active: tab.id == active_id,
        variant: if(tab.id == active_id, do: "primary", else: "ghost")
      }
    end)
  end

  defp deliveries_path(query) when map_size(query) == 0 do
    ~p"/settings/notifications/deliveries"
  end

  defp deliveries_path(query), do: ~p"/settings/notifications/deliveries?#{query}"

  # --- channel form helpers --------------------------------------------------

  defp blank_channel_form(providers) do
    provider = List.first(providers)

    %{
      mode: :new,
      id: nil,
      record: nil,
      provider: provider,
      params: %{
        "name" => "",
        "description" => "",
        "provider_id" => provider && to_string(provider.id),
        "execution_route" => "control_plane",
        "agent_uid" => "",
        "max_attempts" => to_string(provider_default(provider)),
        "rate_limit_per_minute" => "",
        "fallback_channel_id" => "",
        "fail_closed" => "false"
      },
      config_params: %{},
      warnings: [],
      mailer_warning: email_mailer_warning(provider)
    }
  end

  defp channel_form(channel, providers) do
    provider = Enum.find(providers, &(to_string(&1.id) == to_string(channel.provider_id)))

    %{
      mode: :edit,
      id: to_string(channel.id),
      record: channel,
      provider: provider || channel.provider,
      params: %{
        "id" => to_string(channel.id),
        "name" => channel.name || "",
        "description" => channel.description || "",
        "provider_id" => to_string(channel.provider_id),
        "execution_route" => to_string(channel.execution_route),
        "agent_uid" => channel.agent_uid || "",
        "max_attempts" => to_string(channel.max_attempts),
        "rate_limit_per_minute" => stringify(channel.rate_limit_per_minute),
        "fallback_channel_id" => stringify(channel.fallback_channel_id),
        "fail_closed" => to_string(channel.fail_closed)
      },
      # Only the public part of `secret_refs` reaches the form. A stored secret
      # renders as an empty password input with a "leave blank to keep" hint; the
      # resolved value never enters assigns or the DOM.
      config_params: Map.merge(channel.config || %{}, SecretRefs.public_params(channel.secret_refs || %{})),
      warnings: [],
      mailer_warning: email_mailer_warning(provider || channel.provider)
    }
  end

  defp merge_channel_form(nil, params, config, socket) do
    merge_channel_form(blank_channel_form(socket.assigns.providers), params, config, socket)
  end

  defp merge_channel_form(form, params, config, socket) do
    provider =
      Enum.find(socket.assigns.providers, &(to_string(&1.id) == to_string(params["provider_id"]))) ||
        form[:provider]

    merged_params = Map.merge(form.params, params)

    form
    |> Map.put(:params, merged_params)
    |> Map.put(:provider, provider)
    |> Map.put(
      :config_params,
      form.config_params
      |> Kernel.||(%{})
      |> Map.merge(drop_unused_config_keys(config || %{}))
    )
    |> Map.put(:warnings, channel_warnings(merged_params, socket.assigns.channel_index))
    |> Map.put(:mailer_warning, email_mailer_warning(provider))
  end

  defp email_mailer_warning(provider) when is_map(provider) do
    key = Map.get(provider, :provider_key) || Map.get(provider, "provider_key")

    if to_string(key || "") == "email" do
      case OutboundMail.diagnose() do
        :ok -> nil
        {:error, {_class, message}} -> message
      end
    end
  end

  defp email_mailer_warning(_provider), do: nil

  # Failover problems are surfaced before save, not after a delivery fails.
  defp channel_warnings(params, index) do
    fallback_id = blank_to_nil(params["fallback_channel_id"])
    fail_closed? = truthy?(params["fail_closed"])
    fallback = fallback_id && Map.get(index, fallback_id)

    []
    |> add_if(
      fail_closed? and not is_nil(fallback_id),
      "Fail closed is set, so the selected failover channel will never be used. Clear one of the two."
    )
    |> add_if(
      not is_nil(fallback_id) and is_nil(fallback),
      "The selected failover channel is not readable, so failover cannot be verified."
    )
    |> add_if(
      match?(%{enabled: false}, fallback),
      "The selected failover channel is disabled, so a failover to it would be recorded as suppressed with reason channel disabled."
    )
    |> add_if(
      cycles?(params["id"], fallback, index),
      "The selected failover channel points back at this channel, which is a cycle. Failover is one hop and would dead-end."
    )
  end

  defp cycles?(nil, _fallback, _index), do: false
  defp cycles?(_id, nil, _index), do: false

  defp cycles?(id, %{fallback_channel_id: target}, _index) when not is_nil(target) do
    to_string(target) == to_string(id)
  end

  defp cycles?(_id, _fallback, _index), do: false

  defp add_if(list, true, message), do: list ++ [message]
  defp add_if(list, _false, _message), do: list

  defp split_config(form) do
    schema = provider_schema(form[:provider])
    secret_fields = SecretRefs.secret_ref_fields(schema)
    select_keys = Enum.map(secret_fields, &SecretRefs.credential_select_key/1)
    keys = secret_fields ++ select_keys

    {secrets, config} =
      form
      |> Map.get(:config_params, %{})
      |> drop_unused_config_keys()
      |> Enum.split_with(fn {key, _value} -> to_string(key) in keys end)

    {normalize_channel_config(schema, Map.new(config)), Map.new(secrets)}
  end

  # A test send needs plaintext for a secret the operator just typed, and the
  # stored `secretref:` handle for one they left alone. Passing both lets the
  # transport resolve whichever applies, and the plaintext is handed straight to
  # `Request.secrets` without ever entering socket assigns.
  defp test_payload(form) do
    schema = provider_schema(form[:provider])
    secret_fields = SecretRefs.secret_ref_fields(schema)
    params = Map.get(form, :config_params, %{})

    secrets =
      secret_fields
      |> Enum.flat_map(fn field ->
        case blank_to_nil(Map.get(params, field)) do
          nil -> []
          value -> if SecretRefs.secret_ref?(value), do: [], else: [{field, value}]
        end
      end)
      |> Map.new()

    # The typed plaintext is carried in `secrets` only. It is dropped from the
    # config document so a transport that logs or summarises its configuration
    # cannot echo a credential the operator just typed.
    config =
      params
      |> Map.drop(Enum.map(secret_fields, &SecretRefs.credential_select_key/1))
      |> Map.drop(Map.keys(secrets))
      |> then(&normalize_channel_config(schema, &1))

    {config, secrets}
  end

  defp normalize_channel_config(schema, config) when is_map(schema) and is_map(config) do
    ConfigSchema.normalize_params(schema, config)
  end

  defp normalize_channel_config(_schema, config) when is_map(config), do: config
  defp normalize_channel_config(_schema, _config), do: %{}

  # Resolved through the same runtime contract mechanism the form renders from
  # (tasks 3.5.4). Secret-field detection and the test-send payload MUST see the
  # schema the operator actually filled in: reading the stored copy here while
  # the form rendered the package's would classify a package-declared secret as
  # ordinary configuration and put a credential in `config`.
  defp provider_schema(provider), do: Contracts.config_schema(provider)

  defp provider_default(%{default_max_attempts: value}) when is_integer(value), do: value
  defp provider_default(_provider), do: 3

  defp save_channel(scope, %{mode: :new}, attrs, provider_id) do
    NotificationChannel
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :provider_id, blank_to_nil(provider_id)), scope: scope)
    |> Ash.create()
  end

  defp save_channel(scope, %{record: record}, attrs, _provider_id) when not is_nil(record) do
    record
    |> Ash.Changeset.for_update(:update, attrs, scope: scope)
    |> Ash.update()
  end

  defp save_channel(_scope, _form, _attrs, _provider_id), do: {:error, :no_channel}

  defp toggle_channel(socket, id, action, message) do
    scope = socket.assigns.current_scope

    with channel when not is_nil(channel) <- fetch_channel(scope, id),
         {:ok, _updated} <-
           channel |> Ash.Changeset.for_update(action, %{}, scope: scope) |> Ash.update() do
      {:noreply,
       socket
       |> put_flash(:info, message)
       |> assign(:confirmation, nil)
       |> do_load_tab("channels")}
    else
      nil ->
        {:noreply, socket |> assign(:confirmation, nil) |> put_flash(:error, "Channel unavailable.")}

      {:error, reason} ->
        {:noreply, socket |> assign(:confirmation, nil) |> put_flash(:error, error_message(reason))}
    end
  end

  defp toggle_provider(socket, id, action, message) do
    scope = socket.assigns.current_scope

    with provider when not is_nil(provider) <- fetch_provider(scope, id),
         {:ok, _updated} <-
           provider |> Ash.Changeset.for_update(action, %{}, scope: scope) |> Ash.update() do
      {:noreply,
       socket
       |> put_flash(:info, message)
       |> assign(:confirmation, nil)
       |> do_load_tab("providers")}
    else
      nil ->
        {:noreply, socket |> assign(:confirmation, nil) |> put_flash(:error, "Provider unavailable.")}

      {:error, reason} ->
        {:noreply, socket |> assign(:confirmation, nil) |> put_flash(:error, error_message(reason))}
    end
  end

  defp channels_for_provider(scope, provider_id) do
    scope
    |> Data.list_channels()
    |> Enum.filter(&(to_string(&1.provider_id) == to_string(provider_id)))
  end

  # --- declarative provider upload helpers -----------------------------------

  # Every upload and version event resolves its provider the same way: the row is
  # read with the viewer's scope, and a tier that carries no uploadable document
  # is refused by name rather than producing an Ash error the operator cannot
  # act on. `:native` is resolved from a compile-time allowlist and `:wasm_plugin`
  # ships as a signed package, so neither is authorable here.
  defp with_declarative_provider(socket, id, fun) do
    case fetch_provider(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That provider is not available.")}

      %{provider_type: :declarative} = provider ->
        fun.(provider)

      provider ->
        {:noreply, put_flash(socket, :error, not_declarative_message(provider))}
    end
  end

  defp not_declarative_message(provider) do
    "#{provider.display_name} is a #{Presentation.provider_type_label(provider.provider_type)} " <>
      "provider, so it carries no uploaded definition. Only a declarative provider is authored " <>
      "by uploading a document."
  end

  defp upload_form(socket, params) do
    socket.assigns.provider_upload
    |> ProviderUpload.merge(params)
    |> ProviderUpload.validate()
  end

  # A blank document has no validation errors to show, so pressing save on one
  # would otherwise do nothing and say nothing.
  defp nothing_to_save(%{errors: [], error: nil} = form) do
    Map.put(form, :error, "Paste a YAML or JSON definition document first.")
  end

  defp nothing_to_save(form), do: form

  defp save_definition(socket, form, definition) do
    scope = socket.assigns.current_scope

    case provider_for_key(scope, definition.key) do
      nil ->
        create_definition(socket, form, definition)

      %{provider_type: :declarative} = provider ->
        update_definition(socket, form, definition, provider)

      provider ->
        {:noreply, assign(socket, :provider_upload, Map.put(form, :error, key_taken(provider)))}
    end
  end

  defp key_taken(provider) do
    "The key #{provider.provider_key} already belongs to a " <>
      "#{Presentation.provider_type_label(provider.provider_type)} provider. Choose another key: " <>
      "an uploaded document never replaces a provider from another tier."
  end

  defp create_definition(socket, form, definition) do
    NotificationProvider
    |> Ash.Changeset.for_create(:create, ProviderUpload.create_attrs(definition), scope: socket.assigns.current_scope)
    |> Ash.create()
    |> case do
      {:ok, provider} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{provider.display_name} saved as version #{provider.definition_version}. It starts as a draft; activate it to bind channels to it."
         )
         |> assign(:provider_upload, nil)
         |> do_load_tab("providers")}

      {:error, reason} ->
        {:noreply, assign(socket, :provider_upload, Map.put(form, :error, error_message(reason)))}
    end
  end

  defp update_definition(socket, form, definition, provider) do
    attrs = ProviderUpload.update_attrs(definition, provider.definition_version)

    provider
    |> Ash.Changeset.for_update(:update, attrs, scope: socket.assigns.current_scope)
    |> Ash.update()
    |> case do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{updated.display_name} saved as version #{updated.definition_version}. Deliveries already recorded keep naming the version that rendered them."
         )
         |> assign(:provider_upload, nil)
         |> refresh_version_panel(updated)
         |> do_load_tab("providers")}

      {:error, reason} ->
        {:noreply, assign(socket, :provider_upload, Map.put(form, :error, error_message(reason)))}
    end
  end

  defp roll_back(socket, provider, number) do
    scope = socket.assigns.current_scope
    entries = version_entries(scope, provider)

    with entry when not is_nil(entry) <- ProviderVersions.find(entries, number),
         {:ok, definition} <- Definition.parse(entry.definition),
         attrs = ProviderUpload.update_attrs(definition, provider.definition_version),
         {:ok, updated} <-
           provider |> Ash.Changeset.for_update(:update, attrs, scope: scope) |> Ash.update() do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Rolled back to version #{entry.number}, saved as version #{updated.definition_version}."
       )
       |> assign(:confirmation, nil)
       |> refresh_version_panel(updated)
       |> do_load_tab("providers")}
    else
      nil ->
        {:noreply,
         socket
         |> assign(:confirmation, nil)
         |> put_flash(:error, "That provider version is not available.")}

      # `Declarative.Definition` answers with a list of path/message maps. A
      # stored document that no longer validates means the validator got stricter
      # since it was uploaded, and re-applying it would store a document the
      # engine cannot run.
      {:error, [%{path: _path, message: _message} | _rest] = errors} ->
        {:noreply,
         socket
         |> assign(:confirmation, nil)
         |> put_flash(
           :error,
           "Version #{number} is no longer a valid definition: #{Definition.describe_errors(errors)}"
         )}

      {:error, reason} ->
        {:noreply, socket |> assign(:confirmation, nil) |> put_flash(:error, error_message(reason))}
    end
  end

  defp rollback_confirmation(provider, entry, channels) do
    %{
      title: "Roll back to version #{entry.number}?",
      message:
        "Version #{entry.number} of #{provider.display_name} is re-uploaded as version " <>
          "#{ProviderUpload.next_version(provider.definition_version)}. Nothing already delivered " <>
          "changes: every recorded delivery keeps naming the version that rendered it. These " <>
          "channels start rendering from the restored document:",
      event: "rollback_provider",
      confirm_label: "Roll back",
      id: to_string(provider.id),
      version: to_string(entry.number),
      items: Enum.map(channels, & &1.name)
    }
  end

  defp version_panel(socket, provider) do
    scope = socket.assigns.current_scope

    %{
      provider: provider,
      entries: version_entries(scope, provider),
      channels: channels_for_provider(scope, provider.id)
    }
  end

  defp version_entries(scope, provider) do
    scope
    |> Data.list_provider_versions(provider.id)
    |> ProviderVersions.history(provider.definition_version)
  end

  # The panel is only refreshed when it is open on the provider that changed, so
  # a save from the upload editor does not open a panel nobody asked for.
  defp refresh_version_panel(socket, provider) do
    case socket.assigns.provider_versions do
      %{provider: %{id: open_id}} ->
        if to_string(open_id) == to_string(provider.id) do
          assign(socket, :provider_versions, version_panel(socket, provider))
        else
          socket
        end

      _other ->
        socket
    end
  end

  defp provider_for_key(scope, key) do
    NotificationProvider
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(provider_key == ^key)
    |> Ash.Query.limit(1)
    |> Ash.read(scope: scope)
    |> first_or_nil()
  end

  # --- route form helpers ----------------------------------------------------

  defp blank_route_form do
    %{
      mode: :new,
      id: nil,
      record: nil,
      params: %{
        "name" => "",
        "priority" => "100",
        "escalation_policy_id" => "",
        "schedule_id" => "",
        "throttle_seconds" => "",
        "group_wait_seconds" => "0",
        "group_interval_seconds" => "",
        "dedupe_key_template" => "",
        "continue" => "false",
        "combinator" => "all"
      },
      rows: [Predicate.blank_row()],
      raw_expression: false,
      error: nil
    }
  end

  defp route_form(route) do
    {combinator, rows, raw?} =
      case Predicate.from_document(route.match_expression) do
        {:ok, {combinator, rows}} -> {combinator, rows, false}
        :unsupported -> {"all", [], true}
      end

    %{
      mode: :edit,
      id: to_string(route.id),
      record: route,
      params: %{
        "name" => route.name || "",
        "priority" => to_string(route.priority),
        "escalation_policy_id" => stringify(route.escalation_policy_id),
        "schedule_id" => stringify(route.schedule_id),
        "throttle_seconds" => stringify(route.throttle_seconds),
        "group_wait_seconds" => to_string(route.group_wait_seconds),
        "group_interval_seconds" => stringify(route.group_interval_seconds),
        "dedupe_key_template" => route.dedupe_key_template || "",
        "continue" => to_string(route.continue),
        "combinator" => combinator
      },
      rows: rows,
      raw_expression: raw?,
      error: nil
    }
  end

  defp merge_route_form(nil, params), do: merge_route_form(blank_route_form(), params)

  defp merge_route_form(form, params) do
    form
    |> Map.put(:params, Map.merge(form.params, Map.delete(params, "rows")))
    |> Map.put(:rows, indexed_rows(params["rows"], form.rows))
    |> Map.put(:error, nil)
  end

  # A LiveView form posts indexed rows as a map keyed by string index; ordering
  # is restored numerically rather than trusting map order.
  defp indexed_rows(nil, current), do: current

  defp indexed_rows(rows, _current) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {index, _row} -> integer_or_nil(index) || 0 end)
    |> Enum.map(fn {_index, row} -> normalize_row(row) end)
  end

  defp indexed_rows(rows, _current) when is_list(rows), do: Enum.map(rows, &normalize_row/1)
  defp indexed_rows(_rows, current), do: current

  defp normalize_row(%{} = row) do
    %{
      "field" => to_string(Map.get(row, "field", "")),
      "operator" => to_string(Map.get(row, "operator", "equals")),
      "value" => to_string(Map.get(row, "value", ""))
    }
  end

  defp normalize_row(_row), do: Predicate.blank_row()

  defp update_rows(socket, fun) do
    cond do
      socket.assigns.route_form ->
        assign(socket, :route_form, Map.update!(socket.assigns.route_form, :rows, fun))

      socket.assigns.silence_form ->
        assign(socket, :silence_form, Map.update!(socket.assigns.silence_form, :rows, fun))

      true ->
        socket
    end
  end

  defp route_attrs(params, document) do
    %{
      name: blank_to_nil(params["name"]),
      priority: integer_or_default(params["priority"], 100),
      match_expression: document,
      escalation_policy_id: blank_to_nil(params["escalation_policy_id"]),
      schedule_id: blank_to_nil(params["schedule_id"]),
      throttle_seconds: integer_or_nil(params["throttle_seconds"]),
      group_wait_seconds: integer_or_default(params["group_wait_seconds"], 0),
      group_interval_seconds: integer_or_nil(params["group_interval_seconds"]),
      dedupe_key_template: blank_to_nil(params["dedupe_key_template"]),
      continue: truthy?(params["continue"])
    }
  end

  defp save_route(scope, %{mode: :new}, attrs) do
    NotificationRoute
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create()
  end

  defp save_route(scope, %{record: record}, attrs) when not is_nil(record) do
    record
    |> Ash.Changeset.for_update(:update, Map.delete(attrs, :enabled), scope: scope)
    |> Ash.update()
  end

  defp save_route(_scope, _form, _attrs), do: {:error, :no_route}

  defp predicate_error({:unknown_field, field}) do
    "#{field} is not a matchable field. Only the published route field set resolves at dispatch time."
  end

  defp predicate_error({:unknown_operator, operator}) do
    "#{operator} is not a supported operator."
  end

  defp predicate_error(:invalid_combinator), do: "Choose ALL or ANY to combine the conditions."
  defp predicate_error(reason), do: error_message(reason)

  # --- routing preview -------------------------------------------------------

  # Runs the engine's own router over recent alerts so the preview cannot drift
  # from dispatch: the order shown is `Router.evaluation_order/1`, and the route
  # marked terminal is the one `Router.match/3` actually halted on.
  defp routing_preview(socket) do
    scope = socket.assigns.current_scope
    routes = Data.list_routes(scope)

    case recent_alerts(scope, 1) do
      [alert | _rest] ->
        decision =
          NotificationRouter.match(
            alert_subject(alert),
            Enum.map(routes, &route_map/1),
            DateTime.utc_now()
          )

        %{
          description:
            "Evaluated against the most recent active alert (#{Presentation.truncate(alert_title(alert), 60)}), in the order the routing engine uses.",
          rows: preview_rows(routes, decision)
        }

      [] ->
        %{description: "No active alert is available to preview against.", rows: []}
    end
  end

  defp preview_rows(routes, decision) do
    matched_ids = MapSet.new(decision.matched, &to_string(&1.route_id))
    halted = decision.halted_by && to_string(decision.halted_by)
    considered = decision.considered

    routes
    |> Enum.filter(& &1.enabled)
    |> Enum.with_index()
    |> Enum.map(fn {route, index} ->
      id = to_string(route.id)

      cond do
        id == halted ->
          row(
            route,
            "Matched - evaluation stops here",
            "warning",
            "continue is off on this route"
          )

        MapSet.member?(matched_ids, id) ->
          row(route, "Matched", "success", "continue is on, evaluation falls through")

        index < considered ->
          row(route, "Did not match", "ghost", "")

        true ->
          row(route, "Not evaluated", "ghost", "an earlier terminal route stopped evaluation")
      end
    end)
  end

  defp row(route, label, variant, note) do
    %{
      name: route.name,
      priority: route.priority,
      status_label: label,
      status_variant: variant,
      note: note
    }
  end

  defp route_map(route) do
    %{
      id: route.id,
      enabled: route.enabled,
      priority: route.priority,
      continue: route.continue,
      match_expression: route.match_expression,
      escalation_policy_id: route.escalation_policy_id,
      schedule_id: route.schedule_id,
      dedupe_key_template: route.dedupe_key_template
    }
  end

  # --- policy form helpers ---------------------------------------------------

  defp blank_policy_form do
    %{
      mode: :new,
      id: nil,
      record: nil,
      params: %{
        "name" => "",
        "repeat_count" => "0",
        "repeat_interval_seconds" => "300",
        "resolve_notifies" => "true"
      },
      steps: [blank_step(0)],
      warning: nil,
      error: nil
    }
  end

  defp blank_step(index) do
    %{
      "delay_seconds" => to_string(index * 300),
      "condition" => if(index == 0, do: "always", else: "if_unacknowledged"),
      "channel_ids" => []
    }
  end

  defp policy_form(policy) do
    %{
      mode: :edit,
      id: to_string(policy.id),
      record: policy,
      params: %{
        "name" => policy.name || "",
        "repeat_count" => to_string(policy.repeat_count),
        "repeat_interval_seconds" => to_string(policy.repeat_interval_seconds),
        "resolve_notifies" => to_string(policy.resolve_notifies)
      },
      steps: policy_form_steps(policy),
      warning: nil,
      error: nil
    }
  end

  defp policy_form_steps(%{steps: steps}) when is_list(steps) do
    steps
    |> Enum.sort_by(& &1.step_number)
    |> Enum.map(fn step ->
      %{
        "delay_seconds" => to_string(step.delay_seconds),
        "condition" => to_string(step.condition),
        "channel_ids" =>
          step
          |> Map.get(:step_channels, [])
          |> List.wrap()
          |> Enum.map(&to_string(&1.channel_id))
      }
    end)
  end

  defp policy_form_steps(_policy), do: []

  defp merge_policy_form(nil, params), do: merge_policy_form(blank_policy_form(), params)

  defp merge_policy_form(form, params) do
    form
    |> Map.put(:params, Map.merge(form.params, Map.delete(params, "steps")))
    |> Map.put(:steps, indexed_steps(params["steps"], form.steps))
    |> Map.put(:error, nil)
  end

  defp indexed_steps(nil, current), do: current

  defp indexed_steps(steps, _current) when is_map(steps) do
    steps
    |> Enum.sort_by(fn {index, _step} -> integer_or_nil(index) || 0 end)
    |> Enum.map(fn {_index, step} -> normalize_step(step) end)
  end

  defp indexed_steps(steps, _current) when is_list(steps), do: Enum.map(steps, &normalize_step/1)
  defp indexed_steps(_steps, current), do: current

  defp normalize_step(%{} = step) do
    %{
      "delay_seconds" => to_string(Map.get(step, "delay_seconds", "0")),
      "condition" => condition(Map.get(step, "condition")),
      "channel_ids" => step |> Map.get("channel_ids", []) |> List.wrap() |> Enum.map(&to_string/1)
    }
  end

  defp normalize_step(_step), do: blank_step(0)

  # The condition vocabulary is closed; anything else falls back rather than
  # being cast into an atom.
  defp condition("always"), do: "always"
  defp condition("if_unacknowledged"), do: "if_unacknowledged"
  defp condition(_other), do: "always"

  defp update_steps(socket, fun) do
    case socket.assigns.policy_form do
      nil ->
        socket

      form ->
        form = Map.update!(form, :steps, fun)
        assign(socket, :policy_form, with_policy_warning(form, socket.assigns.channel_index))
    end
  end

  defp move(steps, nil, _direction), do: steps

  defp move(steps, index, direction) do
    target = if direction == "up", do: index - 1, else: index + 1

    if target < 0 or target >= length(steps) or index < 0 or index >= length(steps) do
      steps
    else
      a = Enum.at(steps, index)
      b = Enum.at(steps, target)

      steps
      |> List.replace_at(index, b)
      |> List.replace_at(target, a)
    end
  end

  defp with_policy_warning(form, index) do
    sets = Enum.map(form.steps, &(&1["channel_ids"] || []))
    Map.put(form, :warning, EdgeRouteSafety.evaluate(sets, index))
  end

  defp empty_step_number(steps) do
    steps
    |> Enum.find_index(&((&1["channel_ids"] || []) == []))
    |> case do
      nil -> 1
      index -> index + 1
    end
  end

  # Steps are rewritten wholesale and renumbered contiguously from 1, which is
  # what makes add / remove / reorder produce a policy whose step numbers still
  # mean what the timeline showed.
  defp save_policy_and_steps(socket, form) do
    scope = socket.assigns.current_scope

    attrs = %{
      name: blank_to_nil(form.params["name"]),
      repeat_count: integer_or_default(form.params["repeat_count"], 0),
      repeat_interval_seconds: integer_or_default(form.params["repeat_interval_seconds"], 300),
      resolve_notifies: truthy?(form.params["resolve_notifies"])
    }

    with {:ok, policy} <- save_policy(scope, form, attrs),
         :ok <- replace_steps(scope, policy, form.steps) do
      {:noreply,
       socket
       |> put_flash(:info, "Escalation policy saved")
       |> assign(:policy_form, nil)
       |> do_load_tab("routes")}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :policy_form, Map.put(form, :error, error_message(reason)))}
    end
  end

  defp save_policy(scope, %{mode: :new}, attrs) do
    NotificationEscalationPolicy
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create()
  end

  defp save_policy(scope, %{record: record}, attrs) when not is_nil(record) do
    record
    |> Ash.Changeset.for_update(:update, attrs, scope: scope)
    |> Ash.update()
  end

  defp save_policy(_scope, _form, _attrs), do: {:error, :no_policy}

  defp replace_steps(scope, policy, steps) do
    with :ok <- destroy_steps(scope, policy) do
      steps
      |> Enum.with_index(1)
      |> Enum.reduce_while(:ok, fn {step, number}, :ok ->
        case create_step(scope, policy, step, number) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp destroy_steps(scope, policy) do
    NotificationEscalationStep
    |> Ash.Query.for_read(:for_policy, %{policy_id: policy.id})
    |> Ash.read(scope: scope)
    |> case do
      {:ok, steps} ->
        Enum.reduce_while(steps, :ok, fn step, :ok ->
          case Ash.destroy(step, scope: scope) do
            :ok -> {:cont, :ok}
            {:ok, _destroyed} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_step(scope, policy, step, number) do
    attrs = %{
      policy_id: policy.id,
      step_number: number,
      delay_seconds: integer_or_default(step["delay_seconds"], 0),
      condition: condition(step["condition"])
    }

    with {:ok, created} <-
           NotificationEscalationStep
           |> Ash.Changeset.for_create(:create, attrs, scope: scope)
           |> Ash.create() do
      attach_channels(scope, created, step["channel_ids"] || [])
    end
  end

  defp attach_channels(scope, step, channel_ids) do
    Enum.reduce_while(channel_ids, :ok, fn channel_id, :ok ->
      NotificationEscalationStepChannel
      |> Ash.Changeset.for_create(:attach, %{step_id: step.id, channel_id: channel_id}, scope: scope)
      |> Ash.create()
      |> case do
        {:ok, _link} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # --- silence form helpers --------------------------------------------------

  defp blank_silence_form do
    now = DateTime.utc_now()

    %{
      mode: :new,
      id: nil,
      record: nil,
      params: %{
        "name" => "",
        "comment" => "",
        "starts_at" => local_input(now),
        "ends_at" => local_input(DateTime.add(now, 3600, :second)),
        "combinator" => "all"
      },
      rows: [Predicate.blank_row()],
      preview: nil,
      error: nil
    }
  end

  defp silence_form(silence) do
    {combinator, rows} =
      case Predicate.from_document(silence.matchers) do
        {:ok, {combinator, rows}} -> {combinator, rows}
        :unsupported -> {"all", []}
      end

    %{
      mode: :edit,
      id: to_string(silence.id),
      record: silence,
      params: %{
        "name" => silence.name || "",
        "comment" => silence.comment || "",
        "starts_at" => local_input(silence.starts_at),
        "ends_at" => local_input(silence.ends_at),
        "combinator" => combinator
      },
      rows: rows,
      preview: nil,
      error: nil
    }
  end

  defp merge_silence_form(nil, params), do: merge_silence_form(blank_silence_form(), params)

  defp merge_silence_form(form, params) do
    form
    |> Map.put(:params, Map.merge(form.params, Map.delete(params, "rows")))
    |> Map.put(:rows, indexed_rows(params["rows"], form.rows))
    |> Map.put(:error, nil)
  end

  # `created_by_user_id` is taken from the authenticated scope. A submitted value
  # is never read, so a crafted parameter naming another user is discarded rather
  # than stored.
  defp silence_attrs(params, matchers, scope) do
    with {:ok, starts_at} <- parse_datetime(params["starts_at"], DateTime.utc_now()),
         {:ok, ends_at} <- parse_datetime(params["ends_at"], nil) do
      {:ok,
       %{
         name: blank_to_nil(params["name"]),
         comment: blank_to_nil(params["comment"]),
         matchers: matchers,
         starts_at: starts_at,
         ends_at: ends_at,
         created_by_user_id: scope_user_id(scope),
         created_by: scope_user_label(scope)
       }}
    end
  end

  defp save_silence(scope, %{mode: :new}, attrs) do
    NotificationSilence
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create()
  end

  defp save_silence(scope, %{record: record}, attrs) when not is_nil(record) do
    record
    |> Ash.Changeset.for_update(:update, attrs, scope: scope)
    |> Ash.update()
  end

  defp save_silence(_scope, _form, _attrs), do: {:error, :no_silence}

  defp silence_error(:missing_datetime), do: "Both the start and the end of the window are required."

  defp silence_error(:invalid_datetime), do: "The window timestamps could not be read."
  defp silence_error(reason), do: predicate_error(reason)

  # The blast radius an operator is about to commit to, computed with the
  # engine's own evaluator over the recent active alerts.
  defp with_blast_radius(form, scope) do
    case Predicate.to_document(form.params["combinator"], form.rows) do
      {:ok, document} ->
        alerts = recent_alerts(scope, @preview_alert_limit)

        matched =
          Enum.filter(alerts, fn alert ->
            match?(
              {:ok, true},
              Evaluator.evaluate(document, NotificationRouter.subject(alert_subject(alert)))
            )
          end)

        Map.put(form, :preview, %{
          count: length(matched),
          considered: length(alerts),
          sample: matched |> Enum.take(@preview_sample) |> Enum.map(&alert_title/1)
        })

      {:error, _reason} ->
        Map.put(form, :preview, nil)
    end
  end

  # --- alerts ----------------------------------------------------------------

  defp recent_alerts(scope, limit) do
    Alert
    |> Ash.Query.for_read(:active)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, alerts} -> alerts
      {:error, _reason} -> []
    end
  end

  # The routing subject is a plain string-keyed map, matching what the dispatcher
  # builds from an alert snapshot.
  defp alert_subject(alert) do
    %{
      "id" => stringify(alert.id),
      "title" => alert.title,
      "description" => Map.get(alert, :description),
      "severity" => stringify(Map.get(alert, :severity)),
      "status" => stringify(Map.get(alert, :status)),
      "source_type" => stringify(Map.get(alert, :source_type)),
      "source_id" => stringify(Map.get(alert, :source_id)),
      "device_uid" => Map.get(alert, :device_uid),
      "agent_uid" => Map.get(alert, :agent_uid),
      "metadata" => Map.get(alert, :metadata) || %{}
    }
  end

  defp alert_title(%{title: title}) when is_binary(title), do: title
  defp alert_title(_alert), do: "(untitled alert)"

  # --- fetches ---------------------------------------------------------------

  defp fetch_channel(scope, id) do
    NotificationChannel
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load([:provider])
    |> Ash.Query.limit(1)
    |> Ash.read(scope: scope)
    |> first_or_nil()
  end

  defp fetch_route(scope, id) do
    NotificationRoute
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read(scope: scope)
    |> first_or_nil()
  end

  defp fetch_silence(scope, id) do
    NotificationSilence
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read(scope: scope)
    |> first_or_nil()
  end

  defp fetch_provider(scope, id) do
    NotificationProvider
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read(scope: scope)
    |> first_or_nil()
  end

  defp first_or_nil({:ok, records}), do: List.first(records)
  defp first_or_nil(_other), do: nil

  # --- scalars ---------------------------------------------------------------

  defp scope_user_id(%{user: %{id: id}}), do: id
  defp scope_user_id(_scope), do: nil

  defp scope_user_label(%{user: %{email: email}}) when is_binary(email), do: email
  defp scope_user_label(_scope), do: nil

  defp parse_datetime(nil, nil), do: {:error, :missing_datetime}
  defp parse_datetime(nil, default), do: {:ok, default}

  defp parse_datetime(value, default) when is_binary(value) do
    case String.trim(value) do
      "" when is_nil(default) -> {:error, :missing_datetime}
      "" -> {:ok, default}
      trimmed -> parse_naive(trimmed)
    end
  end

  defp parse_datetime(_value, default) when not is_nil(default), do: {:ok, default}
  defp parse_datetime(_value, _default), do: {:error, :invalid_datetime}

  # `datetime-local` submits `YYYY-MM-DDTHH:MM`, which is not a full ISO 8601
  # timestamp; the seconds are appended before parsing rather than left to a
  # parser that would reject it.
  defp parse_naive(value) do
    normalized = if String.length(value) == 16, do: value <> ":00", else: value

    case NaiveDateTime.from_iso8601(normalized) do
      {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
      {:error, _reason} -> {:error, :invalid_datetime}
    end
  end

  defp local_input(%DateTime{} = at) do
    at |> DateTime.truncate(:second) |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
  end

  defp local_input(_at), do: ""

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp drop_unused_config_keys(params) when is_map(params) do
    params
    |> Enum.reject(fn {key, _value} ->
      key |> to_string() |> String.starts_with?("_unused_")
    end)
    |> Map.new()
  end

  defp drop_unused_config_keys(_params), do: %{}

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp integer_or_nil(value) when is_integer(value), do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp integer_or_nil(_value), do: nil

  defp integer_or_default(value, default), do: integer_or_nil(value) || default

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp truthy?(value), do: value in [true, "true", "1", "on", "yes"]

  defp error_message(%Ash.Error.Invalid{} = error) do
    error
    |> Map.get(:errors, [])
    |> Enum.map_join("; ", &ash_error_message/1)
    |> case do
      "" -> "the change was rejected"
      message -> message
    end
  end

  defp error_message(%Ash.Error.Forbidden{}), do: "you are not authorized to make that change"
  defp error_message(reason) when is_binary(reason), do: reason

  defp error_message(reason) when is_atom(reason), do: reason |> to_string() |> String.replace("_", " ")

  defp error_message(reason), do: inspect(reason)

  defp ash_error_message(%{field: field, message: message}) when not is_nil(field) do
    "#{field} #{message}"
  end

  defp ash_error_message(%{message: message}) when is_binary(message), do: message

  defp ash_error_message(error) do
    if is_exception(error), do: Exception.message(error), else: inspect(error)
  end
end
