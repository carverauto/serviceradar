defmodule ServiceRadar.Identity.AliasPolicy do
  @moduledoc """
  Which addresses may be recorded as device aliases.

  Aliases are what DIRE merges devices on, so this predicate is an identity
  control, not a formatting nicety: an address that many devices share must
  never become an alias, or every device carrying it collapses into one.

  This exists as a shared module because the rule was previously enforced in
  exactly one of the two producers. `MapperResultsIngestor` filtered, while the
  `AliasEvents` path -- which is fed by the netprobe NDP census and produces
  every IPv6 alias in the fleet today -- applied no gate at all. The result was
  33 of 40 IPv6 aliases on farm01 being `fe80::` link-local. One predicate, both
  callers.
  """

  @doc """
  Whether `value` may be stored as a device alias.

  Rejected, and why each matters for identity rather than tidiness:

    * loopback (`127/8`, `::1`) -- every device has it
    * unspecified (`0.0.0.0`, `::`) -- a placeholder, not an address
    * link-local (`fe80::/10`, `169.254/16`) -- an interface property. A vendor
      that assigns a fixed `fe80::1` to every router would otherwise merge all
      of them into one device. IPv4 link-local is APIPA, which means "this host
      failed DHCP" and identifies nothing.

  Link-local addresses remain valid on interface records; they are only barred
  from being device *aliases*.
  """
  @spec valid_alias_ip?(term()) :: boolean()
  def valid_alias_ip?(nil), do: false
  def valid_alias_ip?(""), do: false
  def valid_alias_ip?("0.0.0.0"), do: false
  def valid_alias_ip?("::"), do: false
  def valid_alias_ip?("::1"), do: false

  def valid_alias_ip?(value) when is_binary(value) do
    case :inet.parse_address(to_charlist(value)) do
      {:ok, {127, _, _, _}} -> false
      {:ok, {169, 254, _, _}} -> false
      {:ok, {a, _, _, _, _, _, _, _}} when a >= 0xFE80 and a <= 0xFEBF -> false
      {:ok, _} -> true
      _ -> false
    end
  end

  def valid_alias_ip?(_), do: false
end
