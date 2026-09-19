defmodule ServiceRadarWebNGWeb.DashboardLive.Data.NetflowSql do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @doc false
      @spec netflow_map_time_predicate(String.t()) :: String.t()
      def netflow_map_time_predicate("bucket"), do: "f.bucket >= date_trunc('hour', $1::timestamptz)"
      def netflow_map_time_predicate(time_column), do: "f.#{time_column} >= $1"

    end
  end
end
