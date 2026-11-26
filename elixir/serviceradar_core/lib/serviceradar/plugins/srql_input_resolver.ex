defmodule ServiceRadar.Plugins.SRQLInputResolver do
  @moduledoc """
  Resolves policy input definitions by executing SRQL in the control plane.

  Inputs are normalized to `%{name, entity, query, rows}` and are intended to
  feed `ServiceRadar.Plugins.PluginInputPayloadBuilder`. Both `resolve/2` and
  `reduce_pages/4` read an input's whole selection, a page at a time: SRQL
  answers a request that names no limit with 100 rows, so a single read would
  silently cut every larger selection. `resolve/2` collects every row;
  `reduce_pages/4` folds them a page at a time, for a caller that needs only a
  count or a bounded sample and should not hold the whole selection.
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

  @doc """
  Resolves each input definition to its descriptor and every row its query
  selects, reading the selection a page at a time with `reduce_pages/4`. A
  selection that cannot be read whole is an error, never a shorter row list.
  """
  @spec resolve([input_definition()], keyword()) ::
          {:ok, [map()]} | {:error, [String.t()]}
  def resolve(input_defs, opts \\ [])

  def resolve(input_defs, opts) when is_list(input_defs) do
    input_defs
    |> Enum.reduce_while({:ok, []}, fn input_def, {:ok, acc} ->
      case resolve_input(input_def, opts) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, errors} -> {:halt, {:error, errors}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      {:error, _} = error -> error
    end
  end

  def resolve(_input_defs, _opts), do: {:error, ["input definitions must be a list"]}

  defp resolve_input(input_def, opts) do
    with {:ok, descriptor} <- descriptor(input_def),
         {:ok, pages} <-
           reduce_descriptor_pages(descriptor, [], &{:cont, [&1 | &2]}, opts) do
      {:ok, Map.put(descriptor, :rows, pages |> Enum.reverse() |> Enum.concat())}
    end
  end

  @page_limit 1_000

  @doc """
  Reads one input definition a page at a time, folding each page of rows into
  `acc`.

  `fun` receives a page's rows and the accumulator and returns `{:cont, acc}`
  to read the next page or `{:halt, acc}` to stop. Every page is requested with
  an explicit limit of #{@page_limit} rows: SRQL applies a default limit of 100
  when a request omits one, so reading a single page would silently drop the
  rest of the selection. A page that fails to read is an error, never a short
  result, and so is a full page without a cursor. On an offset walk that means
  the selection continues past the cursor window. On a keyset walk the executor
  reports a missing key instead of ending the walk.

  Rows on an offset page must come back in a unique order, or rows with equal
  sort values can move between pages and be skipped. SRQL already ends
  interface orders (history and `latest:true`) on a unique key. Device and
  agent queries append `sort:uid:asc` after any operator-supplied sort. With
  no operator sort, that is the only order, and SRQL pages it by key: each
  page is an index range scan after the previous page's last uid, and the
  cursor window does not apply. An operator-supplied sort stays first, so
  that query keeps offset cursors and the full-page-without-cursor check
  above still fails it past the window. These walks do not use the device
  default order (availability rank, then the first address parsed as `inet`,
  then uid), which is not served by an index.
  """
  @spec reduce_pages(input_definition(), acc, ([map()], acc -> {:cont | :halt, acc}), keyword()) ::
          {:ok, acc} | {:error, [String.t()]}
        when acc: term()
  def reduce_pages(input_def, acc, fun, opts \\ []) when is_function(fun, 2) do
    with {:ok, descriptor} <- descriptor(input_def) do
      reduce_descriptor_pages(descriptor, acc, fun, opts)
    end
  end

  defp descriptor(input_def) do
    with {:ok, descriptor} <- normalize_input_def(input_def),
         :ok <- validate_entity(descriptor.entity) do
      {:ok, descriptor}
    end
  end

  defp reduce_descriptor_pages(descriptor, acc, fun, opts) do
    runner = Keyword.get(opts, :runner, SRQLRunner)

    query_opts =
      opts
      |> Keyword.get(:query_opts, [])
      |> Keyword.put(:limit, @page_limit)

    reduce_page(runner, paged_query(descriptor), query_opts, nil, acc, fun)
  end

  defp paged_query(%{entity: entity, query: query}) when entity in ["agents", "devices"],
    do: query <> " sort:uid:asc"

  defp paged_query(%{query: query}), do: query

  defp reduce_page(runner, query, query_opts, cursor, acc, fun) do
    page_opts = if cursor, do: Keyword.put(query_opts, :cursor, cursor), else: query_opts

    with {:ok, %{rows: rows} = page} <- runner.query_page(query, page_opts),
         {:cont, acc} <- fun.(normalize_rows(rows), acc) do
      case Map.get(page, :next_cursor) do
        next when is_binary(next) and next != "" ->
          reduce_page(runner, query, query_opts, next, acc, fun)

        _no_cursor when length(rows) >= @page_limit ->
          {:error, [format_error(:selection_exceeds_cursor_window)]}

        _last_page ->
          {:ok, acc}
      end
    else
      {:halt, acc} -> {:ok, acc}
      {:ok, unexpected} -> {:error, [format_error({:unexpected_page, unexpected})]}
      {:error, reason} -> {:error, [format_error(reason)]}
    end
  end

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
