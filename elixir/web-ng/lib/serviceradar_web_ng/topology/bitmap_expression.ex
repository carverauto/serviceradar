defmodule ServiceRadarWebNG.Topology.BitmapExpression do
  @moduledoc "Bounded, canonical control expressions for typed bitmap queries."

  alias ServiceRadarWebNG.Topology.BitmapAddress

  @max_bytes 16_384
  @max_predicates 32
  @max_depth 8
  @max_nodes 65

  def parse(params, supported) when is_map(params) and is_list(supported) do
    with :ok <- request_budget(params),
         :ok <- request_keys(params),
         {:ok, kind} <- kind(Map.get(params, "kind", "device")),
         {:ok, tree, _count} <- expression(Map.get(params, "expression", %{"all" => []}), supported, 1, 0),
         {:ok, program} <- bounded_program(tree),
         {:ok, facets} <- facets(Map.get(params, "facets", []), supported),
         {:ok, limit} <- page_limit(Map.get(params, "limit", 128)) do
      {:ok,
       %{
         kind: kind,
         tree: tree,
         program: program,
         digest: :crypto.hash(:sha256, :erlang.term_to_binary({kind, tree})),
         facets: facets,
         limit: limit
       }}
    end
  end

  def parse(_params, _supported), do: {:error, :invalid_query}

  def request_budget(params) do
    # Bound encoding work as well as the encoded control message. No inventory
    # data crosses this path; Arrow and bitmap payloads have separate transports.
    if :erlang.external_size(params) <= @max_bytes do
      case Jason.encode(params) do
        {:ok, bytes} when byte_size(bytes) <= @max_bytes -> :ok
        {:ok, _bytes} -> {:error, :query_budget}
        {:error, _reason} -> {:error, :invalid_query}
      end
    else
      {:error, :query_budget}
    end
  end

  def kind("device"), do: {:ok, :device}
  def kind(_kind), do: {:error, :unsupported_entity}

  def facets(values, supported) when is_list(values) and length(values) <= 50 do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case exact_predicate(value, supported) do
        {:ok, {:predicate, key, value}} -> {:cont, {:ok, [{key, value} | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  def facets(_values, _supported), do: {:error, :query_budget}

  def page_limit(n) when is_integer(n) and n in 1..128, do: {:ok, n}
  def page_limit(_n), do: {:error, :invalid_page_limit}

  defp request_keys(params) do
    if Enum.all?(Map.keys(params), &(&1 in ["kind", "expression", "facets", "limit", "cursor"])),
      do: :ok,
      else: {:error, :invalid_query}
  end

  defp expression(_value, _supported, depth, _count) when depth > @max_depth, do: {:error, :expression_budget}

  defp expression(value, supported, _depth, count)
       when is_map_key(value, "facet") or is_map_key(value, "tag_key_prefix") or is_map_key(value, "ip_cidr") or
              is_map_key(value, "prefix_tag") do
    if count < @max_predicates do
      with {:ok, predicate} <- predicate(value, supported), do: {:ok, predicate, count + 1}
    else
      {:error, :expression_budget}
    end
  end

  defp expression(%{"except" => child} = value, supported, depth, count) when map_size(value) == 1 do
    with {:ok, child, count} <- expression(child, supported, depth + 1, count) do
      {:ok, {:except, child}, count}
    end
  end

  defp expression(value, supported, depth, count) when is_map(value) and map_size(value) == 1 do
    case Map.to_list(value) do
      [{operator, children}] when operator in ["all", "any"] and is_list(children) and length(children) <= 32 ->
        children(children, operator, supported, depth, count)

      _ ->
        {:error, :invalid_expression}
    end
  end

  defp expression(_value, _supported, _depth, _count), do: {:error, :invalid_expression}

  defp children(children, operator, supported, depth, count) do
    children
    |> Enum.reduce_while({:ok, [], count}, fn child, {:ok, acc, count} ->
      case expression(child, supported, depth + 1, count) do
        {:ok, child, count} -> {:cont, {:ok, [child | acc], count}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, children, count} ->
        tree = {if(operator == "all", do: :all, else: :any), children |> Enum.uniq() |> Enum.sort()}
        {:ok, tree, count}

      error ->
        error
    end
  end

  defp exact_predicate(%{"facet" => key, "value" => value} = term, supported)
       when map_size(term) == 2 and is_binary(key) and is_binary(value) and byte_size(key) <= 64 and
              byte_size(value) <= 256 do
    if key not in supported or not String.valid?(value) do
      {:error, :unsupported_facet}
    else
      with {:ok, value} <- literal_text(value, 256), do: {:ok, {:predicate, key, value}}
    end
  end

  defp exact_predicate(_value, _supported), do: {:error, :invalid_predicate}

  defp predicate(%{"facet" => _, "value" => _} = value, supported), do: exact_predicate(value, supported)

  defp predicate(%{"facet" => key, "prefix" => value} = term, supported)
       when map_size(term) == 2 and is_binary(key) and byte_size(key) <= 64 do
    with true <- key in supported, {:ok, value} <- literal_text(value, 256) do
      {:ok, {:value_prefix, key, value}}
    else
      false -> {:error, :unsupported_facet}
      error -> error
    end
  end

  defp predicate(%{"tag_key_prefix" => key} = term, _supported) when map_size(term) == 1 do
    with {:ok, key} <- literal_text(key, 60), do: {:ok, {:tag_key_prefix, key}}
  end

  defp predicate(%{"tag_key_prefix" => key, "value" => value} = term, _supported)
       when map_size(term) == 2 and is_binary(value) and byte_size(value) <= 256 do
    with {:ok, key} <- literal_text(key, 60), {:ok, value} <- literal_text(value, 256) do
      {:ok, {:tag_pair, key, value}}
    else
      _ -> {:error, :invalid_predicate}
    end
  end

  defp predicate(%{"tag_key_prefix" => key, "prefix" => value} = term, _supported) when map_size(term) == 2 do
    with {:ok, key} <- literal_text(key, 60), {:ok, value} <- literal_text(value, 256) do
      {:ok, {:tag_pair_prefix, key, value}}
    end
  end

  defp predicate(%{"ip_cidr" => value} = term, _supported) when map_size(term) == 1 and is_binary(value) do
    if value == String.trim(value) do
      with {:ok, address, mask} <- BitmapAddress.cidr(value), do: {:ok, {:ip_cidr, address, mask}}
    else
      {:error, :invalid_predicate}
    end
  end

  defp predicate(%{"prefix_tag" => %{"source" => source, "label" => label} = selector} = term, _supported)
       when map_size(term) == 1 and map_size(selector) == 2 and is_binary(source) and byte_size(source) in 1..128 and
              is_binary(label) and byte_size(label) in 1..256 do
    if String.valid?(source) and String.valid?(label),
      do: {:ok, {:prefix_tag, source, label}},
      else: {:error, :invalid_predicate}
  end

  defp predicate(_value, _supported), do: {:error, :invalid_predicate}

  defp literal_text(value, maximum) when is_binary(value) and byte_size(value) <= maximum do
    if String.valid?(value) and value != "" and value == String.trim(value),
      do: {:ok, value},
      else: {:error, :invalid_predicate}
  end

  defp literal_text(_value, _maximum), do: {:error, :invalid_predicate}

  defp bounded_program(tree) do
    program = compile(tree)
    if length(program) <= @max_nodes, do: {:ok, program}, else: {:error, :expression_budget}
  end

  defp compile({:predicate, key, value}), do: [{0, key, value, 0}]
  defp compile({:value_prefix, key, value}), do: [{4, key, value, 0}]
  defp compile({:tag_key_prefix, key}), do: [{5, key, "", 0}]
  defp compile({:tag_pair, key, value}), do: [{6, key, value, 0}]
  defp compile({:tag_pair_prefix, key, value}), do: [{7, key, value, 0}]
  defp compile({:ip_cidr, address, mask}), do: [{8, "", address, mask}]
  defp compile({:prefix_tag, source, label}), do: [{:prefix_tag, source, label}]
  defp compile({:except, child}), do: compile(child) ++ [{3, "", "", 1}]

  defp compile({operator, children}),
    do: Enum.flat_map(children, &compile/1) ++ [{if(operator == :all, do: 1, else: 2), "", "", length(children)}]
end
