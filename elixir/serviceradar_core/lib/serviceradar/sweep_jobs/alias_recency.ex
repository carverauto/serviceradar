defmodule ServiceRadar.SweepJobs.AliasRecency do
  @moduledoc """
  Shared alias recency policy for sweep compilation and result attribution.

  See `docs/docs/network-sweeps.md`, Execution Notes, for configuration and behavior.
  Read recency before confirming detected aliases: `DeviceAliasState.confirm_from_sweep`
  refreshes `last_seen_at`. This policy does not mutate alias state or identity resolution.
  """

  alias ServiceRadar.Repo

  @default_max_age_days 30

  @stale_sql """
  SELECT c.ip
  FROM unnest($1::text[], $2::text[]) AS c(ip, device_id)
  JOIN platform.device_alias_states AS a
    ON a.device_id = c.device_id AND a.alias_type = 'ip' AND a.alias_value = c.ip
  WHERE a.last_seen_at < (now() AT TIME ZONE 'utc') - make_interval(days => $3)
  """

  @doc "The window, in days, within which an alias address is swept as its device."
  @spec max_age_days() :: pos_integer()
  def max_age_days do
    case Application.get_env(:serviceradar_core, :sweep_alias_max_age_days) do
      days when is_integer(days) and days > 0 -> days
      _ -> @default_max_age_days
    end
  end

  @doc """
  The addresses among `pairs` (`{ip, device_uid}`) whose alias `last_seen_at` is older
  than the window.
  """
  @spec stale_alias_ips([{String.t(), String.t()}]) :: MapSet.t(String.t())
  def stale_alias_ips([]), do: MapSet.new()

  def stale_alias_ips(pairs) do
    {ips, device_uids} = Enum.unzip(pairs)
    %{rows: rows} = Repo.query!(@stale_sql, [ips, device_uids, max_age_days()])
    MapSet.new(rows, fn [ip] -> ip end)
  end
end
