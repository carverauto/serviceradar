defmodule ServiceRadar.SRQLDeviceMatcher do
  @moduledoc false

  require Ash.Query
  require Logger

  alias ServiceRadar.Inventory.Device

  @field_mappings %{
    "hostname" => :hostname,
    "uid" => :uid,
    "type" => :type_id,
    "os" => :os,
    "status" => :status
  }

  @type filter :: %{
          field: String.t() | nil,
          op: String.t(),
          value: term()
        }

  @spec match_ast(map(), term(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def match_ast(ast, actor, opts \\ []) when is_map(ast) do
    filters = extract_filters(ast)

    query =
      Device
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> apply_filters(filters, opts)
      |> Ash.Query.limit(1)

    case Ash.read_one(query, actor: actor) do
      {:ok, nil} -> {:ok, false}
      {:ok, _device} -> {:ok, true}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec extract_filters(map()) :: [filter()]
  def extract_filters(%{"filters" => filters}) when is_list(filters) do
    Enum.map(filters, fn filter ->
      %{
        field: Map.get(filter, "field"),
        op: Map.get(filter, "op", "eq"),
        value: Map.get(filter, "value")
      }
    end)
  end

  def extract_filters(_), do: []

  @spec apply_filters(Ash.Query.t(), [filter()], keyword()) :: Ash.Query.t()
  def apply_filters(query, filters, opts \\ []) do
    Enum.reduce(filters, query, fn filter, acc ->
      apply_filter(acc, filter, opts)
    end)
  end

  defp apply_filter(query, %{field: field, op: op, value: value}, opts) when is_binary(field) do
    if String.starts_with?(field, "tags.") do
      tag_key = String.replace_prefix(field, "tags.", "")
      apply_tag_filter(query, tag_key, value)
    else
      mapped_field = map_field(field)
      apply_standard_filter(query, mapped_field, op, value)
    end
  rescue
    e ->
      Logger.debug(fn ->
        "#{log_prefix(opts)}: skipping filter #{field} #{op} #{inspect(value)}: #{Exception.message(e)}"
      end)

      query
  end

  defp apply_filter(query, _filter, _opts), do: query

  defp map_field(field), do: Map.get(@field_mappings, field, String.to_existing_atom(field))

  defp apply_standard_filter(query, field, "eq", value) when is_atom(field) do
    Ash.Query.filter_input(query, %{field => %{eq: value}})
  end

  defp apply_standard_filter(query, field, "contains", value) when is_atom(field) do
    Ash.Query.filter_input(query, %{field => %{contains: value}})
  end

  defp apply_standard_filter(query, field, "in", value) when is_atom(field) and is_list(value) do
    Ash.Query.filter_input(query, %{field => %{in: value}})
  end

  defp apply_standard_filter(query, _field, _op, _value), do: query

  defp apply_tag_filter(query, tag_key, tag_value) do
    Ash.Query.filter(query, fragment("tags @> ?", ^%{tag_key => tag_value}))
  end

  defp log_prefix(opts), do: Keyword.get(opts, :log_prefix, "SRQLDeviceMatcher")
end
