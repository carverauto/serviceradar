defmodule ServiceRadar.Automation.Northbound.InvocationService do
  @moduledoc """
  Creates provider-neutral northbound action invocations.

  This service is intentionally provider-agnostic. It validates descriptor and
  provider state, resolves immutable target snapshots, persists the invocation,
  and creates per-target rows. Dispatch is layered on top of the returned
  invocation in later provider-specific adapters.
  """

  alias ServiceRadar.Automation.Northbound
  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionInvocationTarget
  alias ServiceRadar.Automation.Northbound.TargetResolver

  require Ash.Query

  @type launch_attrs :: map()

  @spec create_invocation(launch_attrs(), keyword()) ::
          {:ok, ActionInvocation.t()} | {:error, term()}
  def create_invocation(attrs, opts \\ [])

  def create_invocation(attrs, opts) when is_map(attrs) do
    actor = Keyword.get(opts, :actor)

    with {:ok, descriptor_id} <- required_string(attrs, :descriptor_id),
         {:ok, descriptor} <- fetch_descriptor(descriptor_id, actor),
         :ok <- validate_descriptor(descriptor),
         {:ok, targets} <- normalize_targets(attrs),
         :ok <- validate_target_scopes(descriptor, targets),
         {:ok, target_snapshots} <- TargetResolver.resolve_targets(targets, actor: actor),
         {:ok, invocation} <- persist_invocation(descriptor, target_snapshots, attrs, actor),
         {:ok, _targets} <- persist_invocation_targets(invocation, target_snapshots, actor) do
      reload_invocation(invocation, actor)
    end
  end

  def create_invocation(_attrs, _opts), do: {:error, :invalid_attributes}

  defp fetch_descriptor(id, actor) do
    ActionDescriptor
    |> Ash.Query.for_read(:by_id, %{id: id}, actor: actor)
    |> Ash.Query.load(:provider)
    |> Ash.read_one(actor: actor, domain: Northbound)
    |> case do
      {:ok, nil} -> {:error, :descriptor_not_found}
      {:ok, descriptor} -> {:ok, descriptor}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_descriptor(%ActionDescriptor{enabled: false}), do: {:error, :descriptor_disabled}

  defp validate_descriptor(%ActionDescriptor{provider: %Ash.NotLoaded{}}) do
    {:error, :provider_not_loaded}
  end

  defp validate_descriptor(%ActionDescriptor{provider: %{status: :active}}), do: :ok

  defp validate_descriptor(%ActionDescriptor{provider: %{status: status}}),
    do: {:error, {:provider_not_active, status}}

  defp normalize_targets(attrs) do
    case fetch(attrs, :targets) do
      targets when is_list(targets) and targets != [] -> {:ok, targets}
      _ -> {:error, :targets_required}
    end
  end

  defp validate_target_scopes(descriptor, targets) do
    allowed_scopes = MapSet.new(descriptor.scopes || [])

    targets
    |> Enum.map(&target_scope/1)
    |> Enum.find(&(is_nil(&1) or not MapSet.member?(allowed_scopes, &1)))
    |> case do
      nil -> :ok
      scope -> {:error, {:unsupported_target_scope, scope}}
    end
  end

  defp persist_invocation(descriptor, target_snapshots, attrs, actor) do
    invocation_attrs = %{
      provider_id: descriptor.provider_id,
      descriptor_id: descriptor.id,
      action_id: descriptor.action_id,
      action_version: descriptor.version,
      descriptor_hash: descriptor.descriptor_hash,
      source: normalize_source(fetch(attrs, :source)),
      requested_by_actor_id: actor_id(actor),
      event_handler_id: fetch(attrs, :event_handler_id),
      originating_event_id: fetch(attrs, :originating_event_id),
      target_snapshots: target_snapshots,
      input_values: normalize_map(fetch(attrs, :input_values)),
      metadata:
        attrs
        |> fetch(:metadata)
        |> normalize_map()
        |> Map.put("descriptor_label", descriptor.label)
        |> Map.put("provider_type", to_string(descriptor.provider.provider_type))
    }

    ActionInvocation
    |> Ash.Changeset.for_create(:create, invocation_attrs, actor: actor)
    |> Ash.create(actor: actor, domain: Northbound)
  end

  defp persist_invocation_targets(invocation, target_snapshots, actor) do
    Enum.reduce_while(target_snapshots, {:ok, []}, fn snapshot, {:ok, acc} ->
      attrs = invocation_target_attrs(invocation, snapshot)

      ActionInvocationTarget
      |> Ash.Changeset.for_create(:create, attrs, actor: actor)
      |> Ash.create(actor: actor, domain: Northbound)
      |> case do
        {:ok, target} -> {:cont, {:ok, [target | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp reload_invocation(invocation, actor) do
    ActionInvocation
    |> Ash.Query.for_read(:by_id, %{id: invocation.id}, actor: actor)
    |> Ash.read_one(actor: actor, domain: Northbound)
  end

  defp invocation_target_attrs(invocation, snapshot) do
    %{
      invocation_id: invocation.id,
      target_kind: snapshot |> Map.fetch!("kind") |> String.to_existing_atom(),
      device_uid: Map.get(snapshot, "device_uid"),
      interface_uid: Map.get(snapshot, "interface_uid"),
      target_snapshot: snapshot,
      status: :pending,
      result: %{}
    }
  end

  defp target_scope(target) when is_map(target) do
    case fetch(target, :kind) do
      value when is_atom(value) -> Atom.to_string(value)
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      _ -> nil
    end
  end

  defp target_scope(_target), do: nil

  defp required_string(map, key) do
    case fetch(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, {:missing_field, key}}, else: {:ok, value}

      _ ->
        {:error, {:missing_field, key}}
    end
  end

  defp fetch(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp fetch(_map, _key), do: nil

  defp normalize_map(%{} = map), do: map
  defp normalize_map(_value), do: %{}

  defp normalize_source(value) when value in [:user, :schedule, :event_handler, :system],
    do: value

  defp normalize_source(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "schedule" -> :schedule
      "event_handler" -> :event_handler
      "system" -> :system
      _ -> :user
    end
  end

  defp normalize_source(_value), do: :user

  defp actor_id(%{id: id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      _ -> nil
    end
  end

  defp actor_id(_actor), do: nil
end
