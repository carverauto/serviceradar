defmodule ServiceRadar.Plugins.SRQLInputResolver do
  @moduledoc """
  Resolves policy input definitions by executing SRQL in the control plane.

  Inputs are normalized to `%{name, entity, query, rows}` and are intended to
  feed `ServiceRadar.Plugins.PluginInputPayloadBuilder`.
  """

  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.Plugins.{MapUtils, ValueUtils}

  @supported_entities MapSet.new(["devices", "interfaces"])

  @type input_definition :: %{
          required(:name) => String.t(),
          required(:entity) => String.t(),
          required(:query) => String.t()
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
           {:ok, rows} <- runner.query(descriptor.query, query_opts),
           normalized_rows <- normalize_rows(rows) do
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
      ValueUtils.blank_string?(name) -> {:error, ["input definition is missing name"]}
      ValueUtils.blank_string?(entity) -> {:error, ["input definition is missing entity"]}
      ValueUtils.blank_string?(raw_query) -> {:error, ["input definition is missing query"]}
      true -> {:ok, %{name: name, entity: entity, query: normalize_query(raw_query, entity)}}
    end
  end

  defp normalize_input_def(_), do: {:error, ["input definition must be an object"]}

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
