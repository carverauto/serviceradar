defmodule ServiceRadar.Inventory.Identity.SourceCorroboration do
  @moduledoc """
  The evidence that a source's later observation and an earlier one are one device (change
  `add-source-id-succession`, design D3 and D6).

  Two observations are linked by a hardware MAC, `hardware_macs/1`: universally administered,
  unicast, and neither all-zero nor broadcast. They corroborate each other, `corroboration/2`,
  only when they agree on the source's first-seen time. A name never corroborates (requirement
  "Hostname Agreement Is Not Identity"): many unrelated hosts share a hostname, and a returning
  id whose only second factor is its hostname goes to review instead. `normalize_hostname/1` is
  kept for review classification and evidence only.

  `ServiceRadar.Inventory.Identity.SourceReactivation` judges a retired id reported again with
  these rules (D6). They are the rules of succession (D3) as well.
  """

  alias ServiceRadar.Inventory.Identity.Mac

  @type observation :: %{
          optional(:first_seen) => DateTime.t() | nil
        }

  @doc """
  The hardware MACs among `values` (raw MAC fields or lists of them), normalized: the universally
  administered (`Mac.universal_macs/1`) unicast ones.
  """
  @spec hardware_macs([String.t() | nil] | String.t() | nil) :: MapSet.t(String.t())
  def hardware_macs(values) do
    values
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Mac.universal_macs()
    |> Enum.reject(&Mac.multicast_mac?/1)
    |> MapSet.new()
  end

  @doc "A hostname lower-cased and trimmed, without a trailing dot; nil when blank."
  @spec normalize_hostname(term()) :: String.t() | nil
  def normalize_hostname(hostname) when is_binary(hostname) do
    case hostname |> String.trim() |> String.trim_trailing(".") |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_hostname(_hostname), do: nil

  @doc """
  A source time at the source's precision, whole seconds: a `DateTime`, a `NaiveDateTime`
  (taken as UTC) or an ISO 8601 string. Anything else is nil.
  """
  @spec parse_time(term()) :: DateTime.t() | nil
  def parse_time(%DateTime{} = time), do: DateTime.truncate(time, :second)

  def parse_time(%NaiveDateTime{} = time),
    do: time |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)

  def parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} ->
        parse_time(time)

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, time} -> parse_time(time)
          {:error, _reason} -> nil
        end
    end
  end

  def parse_time(_value), do: nil

  @doc """
  Whether the `later` observation corroborates the `earlier` one: `{:ok, :first_seen}` when
  both carry the same first-seen time, and `:error` otherwise, whatever their hostnames.
  """
  @spec corroboration(observation(), observation()) :: {:ok, :first_seen} | :error
  def corroboration(earlier, later) when is_map(earlier) and is_map(later) do
    if same_time?(
         parse_time(Map.get(earlier, :first_seen)),
         parse_time(Map.get(later, :first_seen))
       ) do
      {:ok, :first_seen}
    else
      :error
    end
  end

  defp same_time?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_time?(_left, _right), do: false
end
