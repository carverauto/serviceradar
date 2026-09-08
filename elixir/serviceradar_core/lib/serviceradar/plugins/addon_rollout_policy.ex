defmodule ServiceRadar.Plugins.AddonRolloutPolicy do
  @moduledoc """
  Normalization and bounded defaults for native add-on rollout controls.
  """

  @defaults %{
    "canary_size" => 1,
    "batch_size" => 10,
    "max_parallel" => 10,
    "soak_seconds" => 300,
    "health_timeout_seconds" => 900,
    "tolerated_failures" => 0
  }

  @spec defaults() :: map()
  def defaults, do: @defaults

  @spec normalize(map() | nil) :: map()
  def normalize(policy) when is_map(policy) do
    policy = stringify_keys(policy)

    %{
      "canary_size" => bounded(policy["canary_size"], 1, 1, 100),
      "batch_size" => bounded(policy["batch_size"], 10, 1, 1_000),
      "max_parallel" => bounded(policy["max_parallel"], 10, 1, 1_000),
      "soak_seconds" => bounded(policy["soak_seconds"], 300, 0, 86_400),
      "health_timeout_seconds" => bounded(policy["health_timeout_seconds"], 900, 30, 86_400),
      "tolerated_failures" => bounded(policy["tolerated_failures"], 0, 0, 100)
    }
  end

  def normalize(_policy), do: @defaults

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp bounded(value, default, min, max) do
    value = parse_integer(value, default)
    value |> Kernel.max(min) |> Kernel.min(max)
  end

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_integer(_value, default), do: default
end
