defmodule ServiceRadarWebNGWeb.DashboardFrameChannel.Actions do
  @moduledoc """
  Plugin action invocation for dashboard packages that declare `actions.invoke`.

  Every call goes through the provider-neutral northbound action model with the
  viewer's own scope: the catalog decides which actions the viewer may launch,
  `InvocationService` records the invocation (audit and action history, with
  the viewer as actor) and dispatches it, and progress is read back through the
  invocation resource's own read policy.
  """

  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.Catalog
  alias ServiceRadar.Automation.Northbound.InvocationService
  alias ServiceRadar.Identity.RBAC, as: CoreRBAC
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Northbound.ActionForm
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @capability "actions.invoke"
  @launch_permission "northbound.actions.launch"
  @scopes ~w(device interface)
  @max_targets 50
  @terminal_states ~w(succeeded failed expired canceled suppressed)

  def capability, do: @capability

  @doc """
  Returns the viewer's launchable actions for a target scope, optionally narrowed
  to one provider type or one plugin.
  """
  def list(scope, capabilities, params) when is_map(params) do
    with :ok <- require_capability(capabilities),
         {:ok, scope} <- authorize(scope),
         {:ok, target_scope} <- target_scope(params) do
      actions =
        scope
        |> eligible_actions(target_scope)
        |> Enum.filter(&matches_narrowing?(&1, params))
        |> Enum.map(&action_payload/1)

      {:ok, actions}
    end
  end

  @doc """
  Creates and dispatches one invocation for the given targets.
  """
  def invoke(scope, capabilities, params) when is_map(params) do
    with :ok <- require_capability(capabilities),
         {:ok, scope} <- authorize(scope),
         {:ok, target_scope} <- target_scope(params),
         {:ok, action} <- find_action(scope, target_scope, params["action_id"]),
         {:ok, targets} <- targets(target_scope, params["targets"]),
         {:ok, input_values} <- ActionForm.parse_input(action, %{"input" => input_params(params)}),
         {:ok, invocation} <- create_invocation(scope, action, targets, input_values, params) do
      {:ok, invocation_payload(invocation), timeout_ms(action)}
    end
  end

  @doc """
  Reads the current state of an invocation with the viewer's scope.
  """
  def progress(scope, invocation_id) when is_binary(invocation_id) do
    ActionInvocation
    |> Ash.Query.for_read(:by_id, %{id: invocation_id}, actor: scope_actor(scope))
    |> Ash.read_one()
    |> case do
      {:ok, %ActionInvocation{} = invocation} -> {:ok, invocation_payload(invocation)}
      _other -> {:error, :progress_unavailable}
    end
  end

  def terminal?(%{"state" => state}), do: state in @terminal_states
  def terminal?(_payload), do: false

  @doc false
  def format_error(:capability_not_approved), do: "dashboard capability is not approved: actions.invoke"
  def format_error(:permission_denied), do: "You are not authorized to launch actions."
  def format_error(:invalid_scope), do: "Action scope must be device or interface."
  def format_error(:too_many_targets), do: "At most #{@max_targets} targets can be launched at once."
  def format_error(:invalid_targets), do: "Targets must name a device (and an interface for interface actions)."
  def format_error(reason), do: ActionForm.format_launch_error(reason, "target")

  defp require_capability(capabilities) do
    if @capability in List.wrap(capabilities), do: :ok, else: {:error, :capability_not_approved}
  end

  defp authorize(scope) do
    case RBAC.authorize_current(scope, [@launch_permission]) do
      {:ok, scope} -> {:ok, scope}
      {:error, _reason} -> {:error, :permission_denied}
    end
  end

  defp target_scope(params) do
    case params["scope"] || "device" do
      scope when scope in @scopes -> {:ok, scope}
      _other -> {:error, :invalid_scope}
    end
  end

  defp eligible_actions(scope, "device"), do: catalog_module().eligible_device_actions(scope)
  defp eligible_actions(scope, "interface"), do: catalog_module().eligible_interface_actions(scope)

  defp matches_narrowing?(action, params) do
    matches_value?(action.provider_type, params["provider_type"]) and
      matches_value?(Map.get(action.metadata || %{}, "plugin_id"), params["plugin_id"])
  end

  defp matches_value?(_value, nil), do: true
  defp matches_value?(_value, ""), do: true
  defp matches_value?(value, expected), do: to_string(value) == to_string(expected)

  defp find_action(scope, target_scope, action_id) when is_binary(action_id) do
    case Enum.find(eligible_actions(scope, target_scope), &(&1.id == action_id)) do
      nil -> {:error, :action_not_found}
      action -> {:ok, action}
    end
  end

  defp find_action(_scope, _target_scope, _action_id), do: {:error, :action_not_found}

  defp targets(_target_scope, targets) when is_list(targets) and length(targets) > @max_targets,
    do: {:error, :too_many_targets}

  defp targets(_target_scope, []), do: {:error, :targets_required}

  defp targets(target_scope, targets) when is_list(targets) do
    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      case target(target_scope, target) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, {:error, :invalid_targets}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp targets(_target_scope, _targets), do: {:error, :targets_required}

  defp target("device", %{"device_uid" => uid}) when is_binary(uid) and uid != "",
    do: {:ok, %{kind: "device", device_uid: uid}}

  defp target("interface", %{"device_uid" => uid, "interface_uid" => iface})
       when is_binary(uid) and uid != "" and is_binary(iface) and iface != "",
       do: {:ok, %{kind: "interface", device_uid: uid, interface_uid: iface}}

  defp target(_target_scope, _target), do: :error

  defp input_params(%{"input" => %{} = input}), do: Map.new(input, fn {key, value} -> {to_string(key), value} end)
  defp input_params(_params), do: %{}

  defp create_invocation(scope, action, targets, input_values, params) do
    invocation_service_module().create_and_dispatch(
      %{
        descriptor_id: Map.get(action, :descriptor_id),
        targets: targets,
        input_values: input_values,
        source: :user,
        metadata: %{
          "ui_surface" => "dashboard_package",
          "dashboard_route_slug" => to_string(params["route_slug"] || ""),
          "selected_target_count" => length(targets)
        }
      },
      actor: scope_actor(scope)
    )
  end

  defp timeout_ms(action) do
    case Map.get(action, :timeout_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds * 1_000
      _other -> 60_000
    end
  end

  defp action_payload(action) do
    %{
      "id" => action.id,
      "label" => action.label,
      "description" => action.description,
      "provider_type" => action.provider_type,
      "provider_name" => action.provider_name,
      "scope" => action.scope,
      "input_schema" => action.input_schema || %{},
      "safety_classification" => action.safety_classification,
      "requires_confirmation" => action.requires_confirmation == true,
      "timeout_seconds" => action.timeout_seconds,
      "plugin_id" => Map.get(action.metadata || %{}, "plugin_id")
    }
  end

  defp invocation_payload(invocation) do
    %{
      "invocation_id" => to_string(invocation.id),
      "state" => to_string(invocation.state),
      "result_summary" => invocation.result_summary || %{},
      "error_message" => invocation.error_message,
      # Jason encodes DateTime as ISO 8601.
      "completed_at" => invocation.completed_at
    }
  end

  defp scope_actor(%{user: %User{} = user}) do
    user
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, CoreRBAC.permissions_for_user(user, fresh?: true))
  end

  defp scope_actor(%{user: user}) when not is_nil(user), do: user
  defp scope_actor(_scope), do: nil

  defp catalog_module do
    Application.get_env(:serviceradar_web_ng, :northbound_catalog_module, Catalog)
  end

  defp invocation_service_module do
    Application.get_env(:serviceradar_web_ng, :northbound_invocation_service_module, InvocationService)
  end
end
