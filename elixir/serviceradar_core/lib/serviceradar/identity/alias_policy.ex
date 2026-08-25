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

  alias ServiceRadar.Inventory.Identity.Address

  @aliasable_classes [:global, :private, :unique_local]

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

  Classification is `Inventory.Identity.Address.classify/1`, not a second
  parser: Address already unwraps `%zone`, `/cidr`, and IPv4-mapped
  `::ffff:a.b.c.d`. Reimplementing that here would accept `::ffff:169.254.1.1`
  as identity evidence.
  """
  @spec valid_alias_ip?(term()) :: boolean()
  def valid_alias_ip?(value) when is_binary(value) do
    Address.classify(value) in @aliasable_classes
  end

  def valid_alias_ip?(_), do: false
end
