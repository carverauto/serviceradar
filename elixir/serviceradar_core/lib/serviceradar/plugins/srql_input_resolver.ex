defmodule ServiceRadar.Plugins.SRQLInputResolver do
  @moduledoc """
  Resolves policy input definitions by executing SRQL in the control plane.

  Inputs are normalized to `%{name, entity, query, rows}` and are intended to
  feed `ServiceRadar.Plugins.PluginInputPayloadBuilder`.
  """

  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.Plugins.MapUtils
  alias ServiceRadar.Plugins.ValueUtils

  @supported_entities MapSet.new(["agents", "devices", "interfaces"])

  # Input definitions arrive with atom keys from Elixir callers and tests,
  # and with string keys from JSON/DB-backed callers (e.g. the producer
  # schedule dispatcher's target-query input). Normalization accepts both,
  # so the type admits both shapes.
  @type input_definition :: %{
          optional(:name | :entity | :query) => String.t(),
          optional(binary()) => String.t()
        }

  @spec resolve([input_definition()], keyword()) ::
          {:ok, [map()]} | {:error, [String.t()]}
  def resolve(input_defs, opts \\ [])

  def resolve(input_defs, opts) when is_list(input_defs) do
    runner = Keyword.get(opts, :runner, SRQLRunner)
    query_opts = Keyword.get(opts, :query_opts, [])

    input_defs
    |> Enum.reduce_while({:ok, []}, fn input_def, {:ok, acc} ->
      with {:ok, descriptor} <- normalize_input_def(input_def),
           :ok <- validate_entity(descriptor.entity),
           {:ok, rows} <- runner.query(descriptor.query, query_opts) do
        normalized_rows = normalize_rows(rows)
        {:cont, {:ok, [Map.put(descriptor, :rows, normalized_rows) | acc]}}
      else
        {:error, errors} when is_list(errors) -> {:halt, {:error, errors}}
        {:error, reason} -> {:halt, {:error, [format_error(reason)]}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      {:error, _} = error -> error
    end
  end

  def resolve(_input_defs, _opts), do: {:error, ["input definitions must be a list"]}

  defp normalize_input_def(input_def) when is_map(input_def) do
    name = ValueUtils.string_value(input_def, [:name, "name"])

    entity =
      input_def |> ValueUtils.string_value([:entity, "entity"]) |> ValueUtils.normalize_entity()

    raw_query = ValueUtils.string_value(input_def, [:query, "query"])

    cond do
      ValueUtils.blank_string?(name) ->
        {:error, ["input definition is missing name"]}

      ValueUtils.blank_string?(entity) ->
        {:error, ["input definition is missing entity"]}

      ValueUtils.blank_string?(raw_query) ->
        {:error, ["input definition is missing query"]}

      true ->
        with {:ok, fields} <- input_fields(input_def, entity) do
          {:ok,
           maybe_put_fields(
             %{name: name, entity: entity, query: normalize_query(raw_query, entity)},
             fields
           )}
        end
    end
  end

  defp normalize_input_def(_), do: {:error, ["input definition must be an object"]}

  @max_input_fields 16
  @column_field ~r/^[a-z][a-z0-9_]{0,63}$/
  @metadata_field ~r/^metadata\.[A-Za-z0-9_-]{1,64}$/
  # Whole metadata maps can carry unrelated or sensitive integration data; only
  # individual `metadata.<key>` values may be projected.
  @whole_map_fields ~w(metadata)

  @doc """
  Validates an input definition's optional `fields`: device field paths the
  payload builder copies into each item. A path is a top-level SRQL device
  column or `metadata.<key>`; anything else is rejected rather than ignored,
  so a typo cannot silently deliver nothing.
  """
  @spec input_fields(map(), String.t()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def input_fields(input_def, entity) do
    case Map.get(input_def, :fields, Map.get(input_def, "fields")) do
      nil ->
        {:ok, []}

      fields when is_list(fields) and length(fields) <= @max_input_fields ->
        validate_input_fields(fields, entity)

      fields when is_list(fields) ->
        {:error, ["input definition lists more than #{@max_input_fields} fields"]}

      _ ->
        {:error, ["input definition fields must be a list"]}
    end
  end

  defp validate_input_fields([], _entity), do: {:ok, []}

  defp validate_input_fields(_fields, entity) when entity != "devices",
    do: {:error, ["input fields are only supported for devices"]}

  defp validate_input_fields(fields, _entity) do
    fields
    |> Enum.map(fn field -> if is_binary(field), do: String.trim(field), else: field end)
    |> Enum.reduce_while({:ok, []}, fn field, {:ok, acc} ->
      if is_binary(field) and field not in @whole_map_fields and
           (Regex.match?(@column_field, field) or Regex.match?(@metadata_field, field)) do
        {:cont, {:ok, [field | acc]}}
      else
        {:halt, {:error, ["invalid input field #{inspect(field)}"]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp maybe_put_fields(descriptor, []), do: descriptor
  defp maybe_put_fields(descriptor, fields), do: Map.put(descriptor, :fields, fields)

  defp validate_entity(entity) do
    if MapSet.member?(@supported_entities, entity) do
      :ok
    else
      {:error, ["unsupported input entity: #{entity}"]}
    end
  end

  defp normalize_query(query, entity) do
    trimmed = String.trim(query)

    case Regex.run(~r/^in:([a-zA-Z0-9_]+)/, trimmed) do
      [_, declared] ->
        if ValueUtils.normalize_entity(declared) == entity do
          trimmed
        else
          "in:#{entity} " <> trimmed
        end

      _ ->
        "in:#{entity} " <> trimmed
    end
  end

  defp normalize_rows(rows) do
    Enum.map(rows, &MapUtils.stringify_keys/1)
  end

  defp format_error(reason), do: "failed to execute SRQL input query: #{inspect(reason)}"
end
