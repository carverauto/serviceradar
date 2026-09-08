defmodule ServiceRadar.Automation.Northbound.History do
  @moduledoc """
  Read helpers for provider-neutral northbound action invocation history.
  """

  alias ServiceRadar.Automation.Northbound
  alias ServiceRadar.Automation.Northbound.ActionInvocationTarget

  require Ash.Query

  @default_limit 10
  @max_limit 50
  @provider_types [:native, :wasm_plugin, :ansible]

  @type history_entry :: %{
          id: String.t(),
          invocation_id: String.t() | nil,
          action_id: String.t() | nil,
          action_label: String.t(),
          provider_name: String.t() | nil,
          provider_type: String.t() | nil,
          source: atom() | nil,
          state: atom() | nil,
          target_status: atom() | nil,
          target_kind: atom() | nil,
          device_uid: String.t() | nil,
          interface_uid: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          redacted_input_values: map(),
          result_summary: map(),
          target_result: map(),
          error_class: String.t() | nil,
          error_message: String.t() | nil,
          external_correlation_id: String.t() | nil,
          next_poll_at: DateTime.t() | nil,
          poll_deadline_at: DateTime.t() | nil,
          last_poll_at: DateTime.t() | nil,
          poll_attempt_count: non_neg_integer()
        }

  @spec list_for_device(String.t(), keyword()) :: {:ok, [history_entry()]} | {:error, term()}
  def list_for_device(device_uid, opts \\ [])

  def list_for_device(device_uid, opts) when is_binary(device_uid) do
    :for_device
    |> target_query(%{device_uid: device_uid}, opts)
    |> read_targets(opts)
  end

  def list_for_device(_device_uid, _opts), do: {:ok, []}

  @spec list_for_interface(String.t(), String.t(), keyword()) ::
          {:ok, [history_entry()]} | {:error, term()}
  def list_for_interface(device_uid, interface_uid, opts \\ [])

  def list_for_interface(device_uid, interface_uid, opts)
      when is_binary(device_uid) and is_binary(interface_uid) do
    :for_interface
    |> target_query(%{device_uid: device_uid, interface_uid: interface_uid}, opts)
    |> read_targets(opts)
  end

  def list_for_interface(_device_uid, _interface_uid, _opts), do: {:ok, []}

  defp target_query(action, args, opts) do
    ActionInvocationTarget
    |> Ash.Query.for_read(action, args)
    |> Ash.Query.load(invocation: [:provider, :descriptor])
    |> maybe_exclude_provider_types(opts)
    |> Ash.Query.limit(normalize_limit(Keyword.get(opts, :limit)))
  end

  defp maybe_exclude_provider_types(query, opts) do
    provider_types = normalize_provider_types(Keyword.get(opts, :exclude_provider_types, []))

    case provider_types do
      [] ->
        query

      provider_types ->
        provider_type_names = Enum.map(provider_types, &Atom.to_string/1)

        Ash.Query.filter(
          query,
          (not is_nil(invocation.provider_id) and
             invocation.provider.provider_type not in ^provider_types) or
            (is_nil(invocation.provider_id) and
               (is_nil(invocation.metadata["provider_type"]) or
                  invocation.metadata["provider_type"] not in ^provider_type_names))
        )
    end
  end

  defp normalize_provider_types(provider_types) when is_list(provider_types) do
    Enum.filter(provider_types, &(&1 in @provider_types))
  end

  defp normalize_provider_types(_provider_types), do: []

  defp read_targets(query, opts) do
    query
    |> Ash.read(ash_opts(opts))
    |> case do
      {:ok, targets} -> {:ok, Enum.map(targets, &entry_from_target/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ash_opts(opts) do
    cond do
      Keyword.has_key?(opts, :scope) -> [scope: Keyword.fetch!(opts, :scope), domain: Northbound]
      Keyword.has_key?(opts, :actor) -> [actor: Keyword.fetch!(opts, :actor), domain: Northbound]
      true -> [domain: Northbound]
    end
  end

  defp entry_from_target(target) do
    invocation = loaded_invocation(target)

    %{
      id: target.id,
      invocation_id: value(invocation, :id),
      action_id: value(invocation, :action_id),
      action_label: action_label(invocation),
      provider_name: provider_name(invocation),
      provider_type: provider_type(invocation),
      source: value(invocation, :source),
      state: value(invocation, :state),
      target_status: target.status,
      target_kind: target.target_kind,
      device_uid: target.device_uid,
      interface_uid: target.interface_uid,
      inserted_at: target.inserted_at,
      started_at: target.started_at || value(invocation, :started_at),
      completed_at: target.completed_at || value(invocation, :completed_at),
      redacted_input_values: value(invocation, :redacted_input_values) || %{},
      result_summary: value(invocation, :result_summary) || %{},
      target_result: target.result || %{},
      error_class: value(invocation, :error_class),
      error_message: value(invocation, :error_message),
      external_correlation_id:
        target.external_correlation_id || value(invocation, :external_correlation_id),
      next_poll_at: target.next_poll_at,
      poll_deadline_at: target.poll_deadline_at,
      last_poll_at: target.last_poll_at,
      poll_attempt_count: target.poll_attempt_count || 0
    }
  end

  defp loaded_invocation(%{invocation: %Ash.NotLoaded{}}), do: nil
  defp loaded_invocation(%{invocation: invocation}), do: invocation
  defp loaded_invocation(_target), do: nil

  defp action_label(invocation) do
    case descriptor(invocation) do
      %{label: label} when is_binary(label) and label != "" -> label
      _ -> value(invocation, :action_id) || "Action"
    end
  end

  defp provider_name(invocation) do
    case provider(invocation) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{source_ref: source_ref} when is_binary(source_ref) and source_ref != "" -> source_ref
      _ -> nil
    end
  end

  defp provider_type(invocation) do
    case provider(invocation) do
      %{provider_type: type} when is_atom(type) -> Atom.to_string(type)
      %{provider_type: type} when is_binary(type) -> type
      _ -> invocation |> value(:metadata) |> metadata_provider_type()
    end
  end

  defp metadata_provider_type(%{} = metadata) do
    case Map.get(metadata, "provider_type") || Map.get(metadata, :provider_type) do
      type when is_atom(type) -> Atom.to_string(type)
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp metadata_provider_type(_metadata), do: nil

  defp provider(nil), do: nil
  defp provider(%{provider: %Ash.NotLoaded{}}), do: nil
  defp provider(%{provider: provider}), do: provider
  defp provider(_invocation), do: nil

  defp descriptor(nil), do: nil
  defp descriptor(%{descriptor: %Ash.NotLoaded{}}), do: nil
  defp descriptor(%{descriptor: descriptor}), do: descriptor
  defp descriptor(_invocation), do: nil

  defp value(nil, _key), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key)

  defp normalize_limit(value) when is_integer(value) do
    value
    |> max(1)
    |> min(@max_limit)
  end

  defp normalize_limit(_value), do: @default_limit
end
