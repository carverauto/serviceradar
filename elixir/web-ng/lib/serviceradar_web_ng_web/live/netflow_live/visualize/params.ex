defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.Params do
  @moduledoc false

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.Config
  alias ServiceRadarWebNGWeb.NetflowVisualize.State, as: NFState

  @default_limit Config.default_limit()
  @max_limit Config.max_limit()

  def nf_param(%{} = state) do
    case NFState.encode_param(state) do
      {:ok, nf} -> nf
      _ -> nil
    end
  end

  def nf_param(_), do: nil

  def srql_submit_extra_params(socket) do
    %{"nf" => nf_param(socket.assigns.netflow_viz_state)}
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  def normalize_optional_string(nil), do: nil
  def normalize_optional_string(""), do: nil

  def normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  def normalize_optional_string(_), do: nil

  def parse_limit_param(nil), do: @default_limit

  def parse_limit_param(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n > 0 -> min(n, @max_limit)
      _ -> @default_limit
    end
  end

  def parse_limit_param(v) when is_integer(v) and v > 0, do: min(v, @max_limit)
  def parse_limit_param(_), do: @default_limit

  def build_patch_url(socket, extra_params) do
    # Intent-only shareable URL: q + nf view chrome. Limit lives in assigns / SRQL;
    # keyset cursor is session position (srql_paginate), not the address bar.
    base = %{
      "q" => Map.get(socket.assigns.srql, :query),
      "nf" => nf_param(Map.get(socket.assigns, :netflow_viz_state))
    }

    params =
      base
      |> Map.merge(extra_params)
      |> Map.drop(["cursor", "page", "limit"])
      |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    "/observability/flows?" <> URI.encode_query(params)
  end

  def merge_nf_state(%{} = current, %{} = incoming) do
    allowed =
      Map.take(incoming, [
        "graph",
        "units",
        "time",
        "limit",
        "limit_type",
        "truncate_v4",
        "truncate_v6",
        "bidirectional",
        "previous_period",
        "dims"
      ])

    next = Map.merge(current, Map.delete(allowed, "dims"))

    if Map.has_key?(allowed, "dims") do
      if Map.get(next, "graph") == "sankey" do
        # Sankey dims are positional and should not require multi-select keyboard interaction.
        dims =
          allowed["dims"]
          |> List.wrap()
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.take(3)

        Map.put(next, "dims", dims)
      else
        Map.put(next, "dims", merge_dim_selection(Map.get(current, "dims", []), allowed["dims"]))
      end
    else
      next
    end
  end

  def merge_dim_selection(current_dims, incoming_dims) do
    current =
      current_dims
      |> List.wrap()
      |> Enum.map(&to_string/1)

    incoming =
      incoming_dims
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    preserved = Enum.filter(current, &Enum.member?(incoming, &1))
    added = Enum.reject(incoming, &Enum.member?(preserved, &1))

    # Prefer "latest selection wins": newly selected dimensions become the primary series.
    # This makes the chart respond immediately when users click additional dimensions.
    Enum.uniq(added ++ preserved)
  end

  def move_dim(dims, dim, "up"), do: move_dim(dims, dim, -1)
  def move_dim(dims, dim, "down"), do: move_dim(dims, dim, 1)

  def move_dim(dims, dim, delta) when is_list(dims) and is_integer(delta) do
    idx = Enum.find_index(dims, &(&1 == dim))

    if is_integer(idx) do
      new_idx = idx + delta

      if new_idx >= 0 and new_idx < length(dims) do
        dims
        |> List.delete_at(idx)
        |> List.insert_at(new_idx, dim)
      else
        dims
      end
    else
      dims
    end
  end
end
