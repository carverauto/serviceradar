defmodule ServiceRadar.SweepJobs.AliasRecency do
  @moduledoc """
  How recently an identity source must have seen a device's IP alias for a sweep to treat
  the address as the device's: `:sweep_alias_max_age_days` (default 30).

  Nothing ages an IP alias out: it stays `confirmed` until something invalidates it, and a
  sweep never refreshes its `last_seen_at`. An address a device left months ago therefore
  kept being swept as the device, and every unanswered probe of it was recorded as the
  device being down.

  Within the window an alias is swept and its results count. Past it, the sweep compiler
  no longer targets it, and a result for it is credited to the device only when the address
  answered: an answer is evidence the device is there, silence at an address it left is not.
  The alias row itself is untouched, so identity resolution reads it as before.
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
  The addresses among `pairs` (`{ip, device_uid}`) the device holds as an alias that no
  identity source has seen within the window.
  """
  @spec stale_alias_ips([{String.t(), String.t()}]) :: MapSet.t(String.t())
  def stale_alias_ips([]), do: MapSet.new()

  def stale_alias_ips(pairs) do
    {ips, device_uids} = Enum.unzip(pairs)
    %{rows: rows} = Repo.query!(@stale_sql, [ips, device_uids, max_age_days()])
    MapSet.new(rows, fn [ip] -> ip end)
  end
end
