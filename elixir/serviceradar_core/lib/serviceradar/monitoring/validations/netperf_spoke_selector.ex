defmodule ServiceRadar.Monitoring.Validations.NetperfSpokeSelector do
  @moduledoc """
  Validates `NetperfPolicy.spoke_selector` map shape and optional `srql_query`.

  Allowed keys: `"partition_id"`, `"tags"`, `"srql_query"`, `"agent_uids"` (string or atom keys).
  If `"srql_query"` is non-blank, it is validated through `ServiceRadar.SRQLTargetQuery`
  and must target `agents` or `devices`.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLTargetQuery

  @allowed_keys ~w(partition_id tags srql_query agent_uids)

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case fetch_selector(changeset) do
      {:ok, nil} ->
        :ok

      {:ok, selector} ->
        validate_selector(selector)

      :error ->
        :ok
    end
  end

  @impl true
  def atomic(changeset, opts, context) do
    case validate(changeset, opts, context) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_selector(changeset) do
    case Ash.Changeset.fetch_change(changeset, :spoke_selector) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case Map.fetch(changeset.atomics || %{}, :spoke_selector) do
          {:ok, value} -> {:ok, value}
          :error -> :error
        end
    end
  end

  defp validate_selector(selector) when not is_map(selector) do
    {:error, field: :spoke_selector, message: "must be a map"}
  end

  defp validate_selector(selector) do
    with :ok <- check_allowed_keys(selector),
         :ok <- check_partition_id(selector),
         :ok <- check_tags(selector),
         :ok <- check_agent_uids(selector) do
      check_srql_query(selector)
    end
  end

  defp check_allowed_keys(selector) do
    unknown =
      selector
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in @allowed_keys))

    if unknown == [] do
      :ok
    else
      {:error,
       field: :spoke_selector,
       message: "contains unsupported selector keys: #{Enum.join(unknown, ", ")}"}
    end
  end

  defp check_partition_id(selector) do
    case fetch_key(selector, "partition_id") do
      nil -> :ok
      value when is_binary(value) -> :ok
      _ -> {:error, field: :spoke_selector, message: "partition_id must be a string"}
    end
  end

  defp check_tags(selector) do
    case fetch_key(selector, "tags") do
      nil ->
        :ok

      tags when is_map(tags) ->
        if Enum.all?(tags, fn {k, v} ->
             (is_binary(k) or is_atom(k)) and (is_binary(v) or is_number(v) or is_boolean(v))
           end) do
          :ok
        else
          {:error, field: :spoke_selector, message: "tags must map string keys to scalar values"}
        end

      _ ->
        {:error, field: :spoke_selector, message: "tags must be a map"}
    end
  end

  defp check_agent_uids(selector) do
    case fetch_key(selector, "agent_uids") do
      nil ->
        :ok

      uids when is_list(uids) ->
        if Enum.all?(uids, &(is_binary(&1) and String.trim(&1) != "")) do
          :ok
        else
          {:error,
           field: :spoke_selector, message: "agent_uids must be a list of non-empty strings"}
        end

      _ ->
        {:error, field: :spoke_selector, message: "agent_uids must be a list"}
    end
  end

  defp check_srql_query(selector) do
    case fetch_key(selector, "srql_query") do
      nil ->
        :ok

      query when is_binary(query) ->
        trimmed = String.trim(query)

        if trimmed == "" do
          :ok
        else
          validate_srql(trimmed)
        end

      _ ->
        {:error, field: :spoke_selector, message: "srql_query must be a string"}
    end
  end

  defp validate_srql(query) do
    case SRQLTargetQuery.validate(query, default_target: :agents) do
      {:ok, normalized} ->
        entity = SRQLAst.entity(normalized)

        if entity in ["agents", "devices"] do
          :ok
        else
          {:error,
           field: :spoke_selector,
           message: "srql_query must target agents (in:agents) or devices (in:devices)"}
        end

      {:error, message} ->
        {:error, field: :spoke_selector, message: message}
    end
  end

  defp fetch_key(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {k, v} when is_atom(k) -> if Atom.to_string(k) == key, do: v
          _ -> nil
        end)
    end
  end
end
