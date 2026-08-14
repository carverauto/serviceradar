defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.Access do
  @moduledoc """
  The authorization surface of `/settings/notifications`, in one place.

  Two things live here, and both exist because the alternative is a silent
  security hole rather than a style preference:

  1. **The tab whitelist.** A tab is selected by a URL path segment, which is
     operator-supplied text. `tab/1` maps that text through a literal list; it
     never calls `String.to_atom/1` or `String.to_existing_atom/1`, so a crafted
     segment cannot mint an atom or reach a tab that does not exist.

  2. **The event permission map.** `permission_for_event/1` names the RBAC key
     every mutating event requires. The LiveView routes *every* `handle_event/3`
     through `authorize_event/2` before it reaches a handler, so an event that is
     forged by a client that never rendered the control is refused with no state
     change, no outbound request, and no database write. A per-clause check would
     be equivalent only as long as nobody adds a clause and forgets; a single
     gate cannot be forgotten.

  The permission keys are the nine three-part `notifications.*` keys published by
  `ServiceRadar.Identity.RBAC.Catalog`. Nothing here invents a key: an unknown
  event is refused rather than defaulting to permitted, because a default-allow
  map turns every future typo into an unauthenticated action.
  """

  alias ServiceRadarWebNG.RBAC

  @channels_view "notifications.channels.view"
  @channels_manage "notifications.channels.manage"
  @routes_view "notifications.routes.view"
  @routes_manage "notifications.routes.manage"
  @providers_manage "notifications.providers.manage"
  @deliveries_view "notifications.deliveries.view"
  @test_send "notifications.test.send"
  @silences_manage "notifications.silences.manage"

  # The Providers tab is readable by anyone who can read the channel registry -
  # a channel is unreadable without knowing what kind of destination it is - and
  # writable only with `notifications.providers.manage`, which uploads
  # executable-adjacent definitions. Silences are read on the routing surface
  # (their read policy is `notifications.routes.view`) and written with their own
  # key, because writing one stops a page.
  @tabs [
    %{
      id: "channels",
      label: "Channels",
      permission: @channels_view,
      manage_permission: @channels_manage
    },
    %{
      id: "routes",
      label: "Routes and Escalation",
      permission: @routes_view,
      manage_permission: @routes_manage
    },
    %{
      id: "silences",
      label: "Silences",
      permission: @routes_view,
      manage_permission: @silences_manage
    },
    %{
      id: "providers",
      label: "Providers",
      permission: @channels_view,
      manage_permission: @providers_manage
    },
    %{
      id: "deliveries",
      label: "Delivery Log",
      permission: @deliveries_view,
      manage_permission: nil
    }
  ]

  @tab_index Map.new(@tabs, &{&1.id, &1})
  @access_permissions @tabs |> Enum.map(& &1.permission) |> Enum.uniq()

  # Every event the LiveView answers, with the key it requires. Read-only events
  # still appear: an event with no entry is refused, so omitting one disables it
  # rather than exposing it.
  @event_permissions %{
    # Channels
    "new_channel" => @channels_manage,
    "edit_channel" => @channels_manage,
    "cancel_channel_form" => @channels_manage,
    "validate_channel" => @channels_manage,
    "save_channel" => @channels_manage,
    "confirm_disable_channel" => @channels_manage,
    "disable_channel" => @channels_manage,
    "enable_channel" => @channels_manage,
    "dismiss_confirmation" => @channels_view,
    "test_channel" => @test_send,
    # Routes and escalation
    "new_route" => @routes_manage,
    "edit_route" => @routes_manage,
    "cancel_route_form" => @routes_manage,
    "validate_route" => @routes_manage,
    "save_route" => @routes_manage,
    "toggle_route" => @routes_manage,
    "move_route" => @routes_manage,
    "add_predicate_row" => @routes_manage,
    "remove_predicate_row" => @routes_manage,
    "new_policy" => @routes_manage,
    "edit_policy" => @routes_manage,
    "cancel_policy_form" => @routes_manage,
    "validate_policy" => @routes_manage,
    "save_policy" => @routes_manage,
    "add_step" => @routes_manage,
    "remove_step" => @routes_manage,
    "move_step" => @routes_manage,
    "preview_routing" => @routes_view,
    # Silences
    "new_silence" => @silences_manage,
    "edit_silence" => @silences_manage,
    "cancel_silence_form" => @silences_manage,
    "validate_silence" => @silences_manage,
    "save_silence" => @silences_manage,
    "confirm_cancel_silence" => @silences_manage,
    "cancel_silence" => @silences_manage,
    # Providers
    "confirm_disable_provider" => @providers_manage,
    "disable_provider" => @providers_manage,
    "enable_provider" => @providers_manage,
    # Declarative provider upload, versioning, and rollback. Every one of these
    # requires `notifications.providers.manage`, including the two that only open
    # a panel: the upload editor renders a stored definition and the version
    # panel renders every superseded one, and a definition is the configuration
    # that decides where a notification is sent.
    "new_provider_upload" => @providers_manage,
    "replace_provider_definition" => @providers_manage,
    "cancel_provider_upload" => @providers_manage,
    "validate_provider_upload" => @providers_manage,
    "save_provider_upload" => @providers_manage,
    "show_provider_versions" => @providers_manage,
    "close_provider_versions" => @providers_manage,
    "confirm_rollback_provider" => @providers_manage,
    "rollback_provider" => @providers_manage,
    # Delivery log
    "filter_deliveries" => @deliveries_view,
    "clear_delivery_filters" => @deliveries_view,
    "show_delivery" => @deliveries_view,
    "close_delivery" => @deliveries_view
  }

  @doc "Every tab, in render order."
  @spec tabs() :: [map()]
  def tabs, do: @tabs

  @doc """
  Resolves an operator-supplied tab segment through the whitelist.

  Returns `:error` for anything that is not a declared tab id. No atom is
  created from the input.
  """
  @spec tab(term()) :: {:ok, map()} | :error
  def tab(id) when is_binary(id), do: Map.fetch(@tab_index, id)
  def tab(_id), do: :error

  @doc "The tabs a scope may see, in render order."
  @spec visible_tabs(term()) :: [map()]
  def visible_tabs(scope), do: Enum.filter(@tabs, &RBAC.can?(scope, &1.permission))

  @doc """
  The tab a scope lands on when none was requested, or `nil` when the scope may
  see no tab at all.
  """
  @spec default_tab(term()) :: map() | nil
  def default_tab(scope), do: scope |> visible_tabs() |> List.first()

  @doc "Whether `scope` may see `tab`."
  @spec visible_tab?(term(), map()) :: boolean()
  def visible_tab?(scope, %{permission: permission}), do: RBAC.can?(scope, permission)

  @doc """
  Whether `scope` may mutate on `tab`. A tab with no management key (the read-only
  Delivery Log) is never manageable.
  """
  @spec manage_tab?(term(), map()) :: boolean()
  def manage_tab?(_scope, %{manage_permission: nil}), do: false
  def manage_tab?(scope, %{manage_permission: permission}), do: RBAC.can?(scope, permission)

  @doc "Whether `scope` may reach the notification settings surface at all."
  @spec any_access?(term()) :: boolean()
  def any_access?(scope), do: visible_tabs(scope) != []

  @doc "The RBAC key `event` requires, or `nil` when the event is not declared."
  @spec permission_for_event(term()) :: String.t() | nil
  def permission_for_event(event) when is_binary(event), do: Map.get(@event_permissions, event)
  def permission_for_event(_event), do: nil

  @doc """
  Authorizes one `handle_event/3` name against the socket scope.

  `{:error, :unknown_event}` is deliberately distinct from
  `{:error, :forbidden}` for the caller's logging, but both refuse: an event
  this module does not declare is not permitted by default.
  """
  @spec authorize_event(term(), term(), module()) ::
          {:ok, term()} | {:error, :forbidden | :unknown_event}
  def authorize_event(scope, event, authorization_module \\ RBAC) do
    case permission_for_event(event) do
      nil ->
        {:error, :unknown_event}

      permission ->
        case authorization_module.authorize_current(scope, [permission]) do
          {:ok, refreshed_scope} -> {:ok, refreshed_scope}
          _denied -> {:error, :forbidden}
        end
    end
  end

  @doc "Refreshes the scope and requires permission to view at least one settings tab."
  @spec authorize_current_access(term(), module()) ::
          {:ok, term()} | {:error, :permission_revoked}
  def authorize_current_access(scope, authorization_module \\ RBAC) do
    authorization_module.authorize_current_any(scope, @access_permissions)
  end

  @doc "Refreshes the scope and requires one current permission."
  @spec authorize_current(term(), String.t(), module()) ::
          {:ok, term()} | {:error, :permission_revoked}
  def authorize_current(scope, permission, authorization_module \\ RBAC) do
    authorization_module.authorize_current(scope, [permission])
  end

  @doc "Permission keys, exposed so a caller does not inline the strings."
  @spec channels_view() :: String.t()
  def channels_view, do: @channels_view

  @spec channels_manage() :: String.t()
  def channels_manage, do: @channels_manage

  @spec routes_view() :: String.t()
  def routes_view, do: @routes_view

  @spec routes_manage() :: String.t()
  def routes_manage, do: @routes_manage

  @spec providers_manage() :: String.t()
  def providers_manage, do: @providers_manage

  @spec deliveries_view() :: String.t()
  def deliveries_view, do: @deliveries_view

  @spec test_send() :: String.t()
  def test_send, do: @test_send

  @spec silences_manage() :: String.t()
  def silences_manage, do: @silences_manage
end
