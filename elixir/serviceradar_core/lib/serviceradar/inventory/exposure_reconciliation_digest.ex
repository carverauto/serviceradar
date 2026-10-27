defmodule ServiceRadar.Inventory.ExposureReconciliationDigest do
  @moduledoc "Versioned, typed actionable-fact fingerprints; count plus SHA-256 sum modulo 2^256."

  @columns ~w(device_ord cve_ord pkg_ord transition_seq device_lifecycle_seq pkgver_ord state
              severity_rank cvss_score kev exploit_available fix_available source_scope)
  @modulus Integer.pow(2, 256)

  def empty, do: %{count: 0, sum: 0}

  def add(acc, row) do
    if Map.fetch!(row, "state") == 1 do
      bytes = ["exposure-fact/v1", Enum.map(@columns, &encode(&1, Map.fetch!(row, &1)))]
      hash = :sha256 |> :crypto.hash(bytes) |> :binary.decode_unsigned()
      %{count: acc.count + 1, sum: rem(acc.sum + hash, @modulus)}
    else
      acc
    end
  end

  def export(acc),
    do: %{"version" => 1, "count" => acc.count, "sum" => Integer.to_string(acc.sum, 16)}

  defp encode(_column, nil), do: <<0>>

  defp encode(column, value)
       when column in ~w(kev exploit_available fix_available) and value in [0, 1],
       do: encode(column, value == 1)

  defp encode("cvss_score", %Decimal{} = value), do: encode("cvss_score", Decimal.to_float(value))
  defp encode("cvss_score", value) when value == 0, do: <<4, 0.0::float-64>>
  defp encode("cvss_score", value) when is_number(value), do: <<4, value * 1.0::float-64>>
  defp encode(_column, false), do: <<2, 0>>
  defp encode(_column, true), do: <<2, 1>>
  defp encode(_column, value) when is_integer(value), do: <<1, value::signed-64>>

  defp encode(_column, value) when is_binary(value),
    do: <<3, byte_size(value)::32, value::binary>>
end
