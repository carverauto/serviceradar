defmodule ServiceRadarWebNG.Topology.BitmapPrefixTags do
  @moduledoc "Bounded local Prefix Tag discovery and immutable label-to-range query adaptation."

  alias ServiceRadar.PrefixTags.Native
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNGWeb.Endpoint

  @cursor_salt "topology-prefix-label-cursor-v1"
  @max_sources 32
  @max_ranges 4_096
  @max_bytes 262_144

  def sources do
    with {:ok, sources} <- Store.sources(@max_sources),
         true <- Enum.all?(sources, &source?/1) do
      {:ok, sources}
    else
      false -> {:error, :prefix_source_budget}
      error -> error
    end
  end

  @doc "Discovery failure is isolated from scalar filter metadata."
  def descriptor do
    base = %{discovery_url: "/topology/query/prefix-tags", sources: [], available: false}

    case sources() do
      {:ok, sources} ->
        entries = Enum.map(sources, &source_descriptor/1)
        %{base | sources: entries, available: Enum.any?(entries, & &1.available)}

      {:error, reason} ->
        Map.put(base, :reason, to_string(reason))
    end
  end

  @doc "Called only by the existing background publisher, with one shared deadline."
  def prepare(sources, deadline) do
    Enum.reduce_while(sources, {:ok, nil}, fn source, _acc ->
      with {:ok, budget} <- BitmapQueries.remaining(deadline),
           {:ok, snapshot} <- capture(source) do
        Native.prepare_catalog(snapshot.trie, budget)
        {:cont, {:ok, nil}}
      else
        {:error, :query_timeout} = error -> {:halt, error}
        _ -> {:cont, {:ok, nil}}
      end
    end)
  end

  @doc "Retains source names whose feature catalog is still in use, for bounded cleanup retries."
  def release(sources) do
    Enum.filter(sources, fn source ->
      with {:ok, snapshot} <- capture(source),
           {:error, _} <- Native.release_catalog(snapshot.trie) do
        true
      else
        _ -> false
      end
    end)
  end

  def resolve(program, deadline) do
    initial = {:ok, [], %{}, 0, 0}

    program
    |> Enum.reduce_while(initial, fn instruction, {:ok, acc, captured, ranges, bytes} ->
      case resolve_instruction(instruction, captured, ranges, bytes, deadline) do
        {:ok, instruction, captured, ranges, bytes} ->
          {:cont, {:ok, [instruction | acc], captured, ranges, bytes}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, compiled, captured, _, _} ->
        {:ok, Enum.reverse(compiled), Map.new(captured, fn {source, snapshot} -> {source, snapshot.version} end)}

      error ->
        error
    end
  end

  def current(versions) when map_size(versions) <= @max_sources do
    Enum.reduce_while(versions, :ok, fn {source, expected}, :ok ->
      case Store.capture(source) do
        {:ok, %{version: ^expected}} -> {:cont, :ok}
        _ -> {:halt, {:error, :source_changed}}
      end
    end)
  end

  def page(params, authority, deadline) do
    with true <- Enum.all?(Map.keys(params), &(&1 in ["source", "cursor", "limit"])),
         source = Map.get(params, "source"),
         true <- source?(source),
         {:ok, limit} <- limit(Map.get(params, "limit", 50)),
         {:ok, after_label} <- after_label(Map.get(params, "cursor"), source, authority),
         {:ok, snapshot} <- capture(source),
         {:ok, budget} <- BitmapQueries.remaining(deadline),
         {:ok, page} <- Native.label_page(snapshot.trie, after_label, limit, budget),
         :ok <- current(%{source => snapshot.version}) do
      cursor =
        if page.next_after,
          do: Phoenix.Token.sign(Endpoint, @cursor_salt, {source, authority, page.next_after})

      {:ok, %{source: source, version: snapshot.version, labels: page.labels, cursor: cursor}}
    else
      false -> {:error, :invalid_query}
      nil -> {:error, :invalid_query}
      error -> error
    end
  end

  defp source_descriptor(source) do
    with {:ok, snapshot} <- capture(source),
         {:ok, status} <- Native.catalog_status(snapshot.trie) do
      %{source: source, version: snapshot.version, available: status.available}
    else
      _ -> %{source: source, available: false}
    end
  end

  defp resolve_instruction({:prefix_tag, source, label}, captured, ranges, bytes, deadline) do
    with true <- ranges < @max_ranges and bytes < @max_bytes,
         {:ok, snapshot} <- capture(source, captured),
         {:ok, budget} <- BitmapQueries.remaining(deadline),
         {:ok, packed} <-
           Native.label_ranges(snapshot.trie, label, @max_ranges - ranges, @max_bytes - bytes, budget) do
      {:ok, {9, "", packed, 0}, Map.put(captured, source, snapshot), ranges + div(byte_size(packed), 33),
       bytes + byte_size(packed)}
    else
      false -> {:error, :prefix_range_budget}
      error -> error
    end
  end

  defp resolve_instruction(instruction, captured, ranges, bytes, _deadline),
    do: {:ok, instruction, captured, ranges, bytes}

  defp capture(source, captured) do
    case Map.fetch(captured, source) do
      {:ok, snapshot} -> {:ok, snapshot}
      :error -> capture(source)
    end
  end

  defp capture(source) do
    case Store.capture(source) do
      {:ok, %{trie: trie} = snapshot} when is_reference(trie) -> {:ok, snapshot}
      _ -> {:error, :prefix_source_unavailable}
    end
  end

  defp after_label(nil, _source, _authority), do: {:ok, nil}

  defp after_label(cursor, source, authority) when is_binary(cursor) and byte_size(cursor) <= 4_096 do
    case Phoenix.Token.verify(Endpoint, @cursor_salt, cursor, max_age: 300) do
      {:ok, {^source, ^authority, label}} when is_binary(label) and byte_size(label) in 1..256 -> {:ok, label}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp after_label(_cursor, _source, _authority), do: {:error, :invalid_cursor}
  defp limit(value) when is_integer(value) and value in 1..50, do: {:ok, value}

  defp limit(value) when is_binary(value) and byte_size(value) in 1..2 do
    case Integer.parse(value) do
      {number, ""} -> limit(number)
      _ -> {:error, :invalid_page_limit}
    end
  end

  defp limit(_value), do: {:error, :invalid_page_limit}
  defp source?(value), do: is_binary(value) and byte_size(value) in 1..128 and String.valid?(value)
end
