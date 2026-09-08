defmodule ServiceRadar.Inventory.Discovery.Decoders.Timestamps do
  @moduledoc """
  Formats a Unix nanosecond timestamp exactly as Go's `time.RFC3339Nano` does.

  This exists because the obvious Elixir spelling is wrong in two ways at once,
  and both are silent.

  `DateTime.from_unix!(nano, :nanosecond) |> DateTime.to_iso8601()` gives
  `"2023-11-14T22:14:20.000000Z"` where Go gives `"2023-11-14T22:14:20Z"`. Go's
  `.999999999` format verb strips trailing zeros and omits the decimal point
  entirely when the fraction is zero; Elixir emits fixed microsecond precision.

  Separately, `DateTime` carries at most MICROSECOND precision, so a genuine
  nanosecond timestamp -- which is what `bpf_ktime_get_ns` produces and what
  netprobe puts on the wire -- loses its last three digits on the way through.

  These strings are not cosmetic. They land in `_alias_last_seen_at` and
  `ip_alias:<ip>` metadata that device alias resolution reads, so a value that
  differs from what the agent produced is a value that does not match.

  Formatting from the integer directly avoids both problems.
  """

  @nanos_per_second 1_000_000_000

  @doc """
  Format nanoseconds since the Unix epoch as Go's `time.RFC3339Nano`.

  Returns `""` for a non-positive or non-integer input, matching the Go
  translator's `observedAtUnixNano/1`, which yields a zero time for `nano <= 0`
  and is then rendered as an empty string rather than as year 1.
  """
  @spec rfc3339_nano(term()) :: String.t()
  def rfc3339_nano(nano) when is_integer(nano) and nano > 0 do
    seconds = div(nano, @nanos_per_second)
    fraction = rem(nano, @nanos_per_second)

    base =
      seconds
      |> DateTime.from_unix!(:second)
      |> DateTime.to_iso8601()
      |> String.replace_suffix("Z", "")

    base <> fraction_suffix(fraction) <> "Z"
  end

  def rfc3339_nano(_nano), do: ""

  # Go's `.999999999`: trailing zeros removed, and the whole fractional part --
  # decimal point included -- omitted when nothing is left.
  defp fraction_suffix(0), do: ""

  defp fraction_suffix(fraction) do
    digits =
      fraction
      |> Integer.to_string()
      |> String.pad_leading(9, "0")
      |> String.replace(~r/0+$/, "")

    if digits == "", do: "", else: "." <> digits
  end
end
