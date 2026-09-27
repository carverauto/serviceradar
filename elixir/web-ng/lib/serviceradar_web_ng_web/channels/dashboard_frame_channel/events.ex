defmodule ServiceRadarWebNGWeb.DashboardFrameChannel.Events do
  @moduledoc """
  Live OCSF event subscriptions for dashboard packages that declare
  `events.subscribe`.

  EventWriter broadcasts a summary of every persisted event row on
  `ServiceRadar.Events.PubSub.rows_topic/0`. A dashboard channel subscribes to
  that topic once, matches each summary against the renderer's filters, and
  pushes only matching events. Delivery is authorized against the
  `ServiceRadar.Monitoring.OcsfEvent` read policy for the viewer on every batch,
  so a viewer who loses event access stops receiving events.
  """

  alias ServiceRadar.Monitoring.OcsfEvent

  @capability "events.subscribe"
  @max_subscriptions 8
  @max_events_per_push 200
  @max_metadata_keys 8

  def capability, do: @capability
  def max_subscriptions, do: @max_subscriptions

  @doc """
  Validates a subscription request and returns its normalized filter.
  """
  def subscribe(scope, capabilities, subscriptions, params) when is_map(params) do
    with :ok <- require_capability(capabilities),
         :ok <- authorize(scope),
         {:ok, id} <- subscription_id(params["id"]),
         :ok <- ensure_capacity(subscriptions, id),
         {:ok, filter} <- normalize_filter(params["filter"]) do
      {:ok, id, filter}
    end
  end

  def readable?(scope), do: authorize(scope) == :ok

  @doc """
  Returns `[{subscription_id, events}]` for every subscription that matched at
  least one summary, capped per push.
  """
  def match(subscriptions, summaries) when is_map(subscriptions) and is_list(summaries) do
    subscriptions
    |> Enum.map(fn {id, filter} ->
      {id, summaries |> Enum.filter(&matches?(filter, &1)) |> Enum.take(@max_events_per_push)}
    end)
    |> Enum.reject(fn {_id, events} -> events == [] end)
  end

  @doc false
  def matches?(filter, summary) do
    Enum.all?(filter, fn {key, expected} -> field_matches?(key, expected, summary) end)
  end

  def format_error(:capability_not_approved), do: "dashboard capability is not approved: events.subscribe"
  def format_error(:permission_denied), do: "You are not authorized to read events."
  def format_error(:invalid_subscription_id), do: "A subscription id is required."
  def format_error(:too_many_subscriptions), do: "At most #{@max_subscriptions} event subscriptions are allowed."
  def format_error({:invalid_filter, key}), do: "Unsupported event filter: #{key}"
  def format_error(_reason), do: "Event subscription failed."

  defp require_capability(capabilities) do
    if @capability in List.wrap(capabilities), do: :ok, else: {:error, :capability_not_approved}
  end

  defp authorize(%{user: user}) when not is_nil(user) do
    if Ash.can?({OcsfEvent, :read}, user), do: :ok, else: {:error, :permission_denied}
  end

  defp authorize(_scope), do: {:error, :permission_denied}

  defp subscription_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> {:error, :invalid_subscription_id}
      trimmed when byte_size(trimmed) <= 64 -> {:ok, trimmed}
      _long -> {:error, :invalid_subscription_id}
    end
  end

  defp subscription_id(_id), do: {:error, :invalid_subscription_id}

  defp ensure_capacity(subscriptions, id) do
    if Map.has_key?(subscriptions, id) or map_size(subscriptions) < @max_subscriptions,
      do: :ok,
      else: {:error, :too_many_subscriptions}
  end

  @doc """
  Normalizes a renderer-supplied filter. Keys are matched as strings; no atoms
  are created from input.
  """
  def normalize_filter(nil), do: {:ok, %{}}

  def normalize_filter(%{} = filter) do
    Enum.reduce_while(filter, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_entry(to_string(key), value) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, to_string(key), normalized)}}
        :error -> {:halt, {:error, {:invalid_filter, key}}}
      end
    end)
  end

  def normalize_filter(_filter), do: {:error, {:invalid_filter, "filter"}}

  defp normalize_entry(key, value) when key in ["log_provider", "log_name", "device_uid"], do: string_set(value)

  defp normalize_entry("class_uid", value), do: integer_set(value)

  defp normalize_entry("min_severity_id", value) when is_integer(value), do: {:ok, value}

  defp normalize_entry("metadata", %{} = value) when map_size(value) <= @max_metadata_keys do
    if Enum.all?(value, fn {_key, expected} -> scalar?(expected) end),
      do: {:ok, Map.new(value, fn {key, expected} -> {to_string(key), to_string(expected)} end)},
      else: :error
  end

  defp normalize_entry(_key, _value), do: :error

  defp string_set(value) when is_binary(value), do: {:ok, MapSet.new([value])}

  defp string_set(values) when is_list(values) and values != [] do
    if Enum.all?(values, &is_binary/1), do: {:ok, MapSet.new(values)}, else: :error
  end

  defp string_set(_value), do: :error

  defp integer_set(value) when is_integer(value), do: {:ok, MapSet.new([value])}

  defp integer_set(values) when is_list(values) and values != [] do
    if Enum.all?(values, &is_integer/1), do: {:ok, MapSet.new(values)}, else: :error
  end

  defp integer_set(_value), do: :error

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  defp field_matches?("device_uid", expected, summary), do: MapSet.member?(expected, get_in(summary, ["device", "uid"]))

  defp field_matches?("min_severity_id", minimum, summary) do
    case summary["severity_id"] do
      severity when is_integer(severity) -> severity >= minimum
      _other -> false
    end
  end

  defp field_matches?("metadata", expected, summary) do
    metadata = summary["metadata"] || %{}
    Enum.all?(expected, fn {key, value} -> to_string(Map.get(metadata, key)) == value end)
  end

  defp field_matches?(key, %MapSet{} = expected, summary), do: MapSet.member?(expected, summary[key])
end
