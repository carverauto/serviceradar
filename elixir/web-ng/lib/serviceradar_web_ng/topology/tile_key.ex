defmodule ServiceRadarWebNG.Topology.TileKey do
  @moduledoc "Canonical world tile keys shared by HTTP requests and channel watches."

  @enforce_keys [:layout_version, :z, :x, :y]
  defstruct [:layout_version, :z, :x, :y, external: false]

  @max_zoom 24
  @max_watched_tiles 64

  def parse(%{"layout_version" => version, "z" => z, "x" => x, "y" => y} = params) do
    case external_layer(params) do
      {:ok, external} -> new(version, z, x, y, external: external)
      _ -> {:error, :invalid_tile}
    end
  end

  def parse(_params), do: {:error, :invalid_tile}

  def new(version, z, x, y, opts \\ []) do
    external = Keyword.get(opts, :external, false) == true

    with {:ok, version} <- layout_version(version),
         {:ok, z} <- coordinate(z),
         true <- z <= @max_zoom,
         {:ok, x} <- coordinate(x),
         {:ok, y} <- coordinate(y),
         true <- x < Integer.pow(2, z) and y < Integer.pow(2, z) do
      {:ok, %__MODULE__{layout_version: version, z: z, x: x, y: y, external: external}}
    else
      _ -> {:error, :invalid_tile}
    end
  end

  def layout_version(version) when is_binary(version) and byte_size(version) == 36 do
    case Ecto.UUID.cast(version) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> {:error, :invalid_layout_version}
    end
  end

  def layout_version(_version), do: {:error, :invalid_layout_version}

  def content_revision(revision) when is_binary(revision) and byte_size(revision) == 64 do
    if String.match?(revision, ~r/\A[0-9a-f]{64}\z/), do: {:ok, revision}, else: {:error, :invalid_revision}
  end

  def content_revision(_revision), do: {:error, :invalid_revision}

  def watch(%{"layout_version" => version, "tiles" => tiles} = params)
      when is_list(tiles) and length(tiles) <= @max_watched_tiles do
    with {:ok, version} <- layout_version(version),
         {:ok, external} <- external_layer(params) do
      tiles
      |> Enum.reduce_while({:ok, [], %{}}, fn tile, {:ok, keys, revisions} ->
        with {:ok, key} <- watch_key(version, tile, external),
             {:ok, revision} <- confirmed_revision(tile) do
          revisions = if revision, do: Map.put(revisions, id(key), revision), else: revisions
          {:cont, {:ok, [key | keys], revisions}}
        else
          _ -> {:halt, {:error, :invalid_tiles}}
        end
      end)
      |> case do
        {:ok, keys, revisions} ->
          {:ok, %{layout_version: version, keys: keys |> Enum.reverse() |> Enum.uniq(), tiles: revisions}}

        error ->
          error
      end
    else
      {:error, :invalid_layout_version} = error -> error
      _ -> {:error, :invalid_tiles}
    end
  end

  def watch(_params), do: {:error, :invalid_tiles}

  def id(%__MODULE__{z: z, x: x, y: y}), do: "#{z}/#{x}/#{y}"

  def low_zoom(%{layout_version: version, zmax: zmax}) do
    for z <- 0..min(zmax, 2), x <- 0..(Integer.pow(2, z) - 1), y <- 0..(Integer.pow(2, z) - 1) do
      %__MODULE__{layout_version: version, z: z, x: x, y: y}
    end
  end

  def transform(%__MODULE__{z: z, x: x, y: y}) do
    width = Integer.pow(2, 24 - z)
    %{origin_x: x * width, origin_y: y * width, scale: width / 65_535}
  end

  defp watch_key(version, %{"z" => z, "x" => x, "y" => y}, external), do: new(version, z, x, y, external: external)

  defp watch_key(_version, _tile, _external), do: {:error, :invalid_tile}

  defp external_layer(params) do
    case Map.get(params, "layers") do
      nil -> {:ok, false}
      "" -> {:ok, false}
      "external" -> {:ok, true}
      _ -> {:error, :invalid_layer}
    end
  end

  defp confirmed_revision(%{"revision" => nil}), do: {:ok, nil}

  defp confirmed_revision(%{"revision" => revision}), do: content_revision(revision)
  defp confirmed_revision(_tile), do: {:ok, nil}

  defp coordinate(value) when is_integer(value) and value >= 0 and value < 16_777_216, do: {:ok, value}

  defp coordinate(value) when is_binary(value) and byte_size(value) in 1..8 do
    case Integer.parse(value) do
      {number, ""} when number >= 0 ->
        if Integer.to_string(number) == value, do: coordinate(number), else: {:error, :invalid_coordinate}

      _ ->
        {:error, :invalid_coordinate}
    end
  end

  defp coordinate(_value), do: {:error, :invalid_coordinate}
end
