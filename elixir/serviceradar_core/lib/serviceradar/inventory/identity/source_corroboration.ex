defmodule ServiceRadar.Inventory.Identity.SourceCorroboration do
  @moduledoc """
  The evidence that a source's later observation and an earlier one are one device (change
  `add-source-id-succession`, design D3 and D6).

  Two observations are linked by a hardware MAC, `hardware_macs/1`: universally administered,
  unicast, and neither all-zero nor broadcast. They corroborate each other, `corroboration/2`,
  when they agree on the source's first-seen time, or on the normalized hostname when the source
  first saw the later observation no earlier than it last saw the earlier one. The time guard is
  what separates a device that came back from a clone of it: cloned machines share a hostname
  while both are in the source, so one was first seen while the other was still being seen. A
  missing time fails the guard.

  `ServiceRadar.Inventory.Identity.SourceReactivation` judges a retired id reported again with
  these rules (D6). They are the rules of succession (D3) as well, which adds one of its own: a
  hostname held by more than one current record of the source does not corroborate.
  """

  alias ServiceRadar.Inventory.Identity.Mac

  @type observation :: %{
          optional(:first_seen) => DateTime.t() | nil,
          optional(:last_seen) => DateTime.t() | nil,
          optional(:hostnames) => [String.t() | nil]
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
  both carry the same first-seen time, `{:ok, :hostname}` when they share a normalized hostname
  and `later` was first seen no earlier than `earlier` was last seen, and `:error` otherwise.
  """
  @spec corroboration(observation(), observation()) :: {:ok, :first_seen | :hostname} | :error
  def corroboration(earlier, later) when is_map(earlier) and is_map(later) do
    earlier_first = parse_time(Map.get(earlier, :first_seen))
    later_first = parse_time(Map.get(later, :first_seen))

    cond do
      same_time?(earlier_first, later_first) ->
        {:ok, :first_seen}

      shared_hostname?(earlier, later) and
          seen_after?(later_first, parse_time(Map.get(earlier, :last_seen))) ->
        {:ok, :hostname}

      true ->
        :error
    end
  end

  defp shared_hostname?(earlier, later) do
    not MapSet.disjoint?(hostnames(earlier), hostnames(later))
  end

  defp hostnames(observation) do
    observation
    |> Map.get(:hostnames, [])
    |> List.wrap()
    |> Enum.map(&normalize_hostname/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp same_time?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_time?(_left, _right), do: false

  defp seen_after?(%DateTime{} = first_seen, %DateTime{} = last_seen),
    do: DateTime.compare(first_seen, last_seen) != :lt

  defp seen_after?(_first_seen, _last_seen), do: false
end
