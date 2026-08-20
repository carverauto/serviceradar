defmodule ServiceRadar.Notifications.SeedFingerprint do
  @moduledoc """
  The divergence test the notification seeders share.

  A first-party row ships `managed: true`, a `template_version`, and a
  `template_fingerprint` over exactly the fields the seeder owns. On the next
  boot the seeder recomputes the fingerprint **from the stored row** and compares
  it with the stored fingerprint:

    * equal - the row is still what the seeder last wrote, so a newer template
      version may be applied on top of it;
    * different - an operator changed a seeder-owned field, so the row is theirs
      and the release leaves it alone.

  That is the whole mechanism by which a release advances a managed default
  while preserving an operator's edit, and it is copied from
  `ServiceRadar.Observability.RuleSeeder`, which has carried it for the preset
  rules. It lives here rather than being written twice because the provider
  seeder and the template seeder must agree on it exactly: two canonicalisations
  that differ by so much as atom-versus-string would each consider the other's
  rows diverged, and the visible symptom would be "upgrades silently stopped
  reconciling", months later.

  ## A nil fingerprint is diverged

  A managed row with no fingerprint predates the mechanism, and nothing can be
  said about whether its content is still the shipped content. Treating it as
  diverged is the safe direction: the worst case is a stale default that an
  operator can re-adopt deliberately, where the other direction silently
  overwrites wording an on-call team has learned to read.

  ## Canonical form

  Values are hashed through a canonical term - keys stringified and sorted,
  atoms stringified - because a seeded template is written from Elixir with atom
  keys and atom values and read back from `jsonb` with string keys. Without
  that, every managed row would look diverged on the first boot after it was
  written.

  ## Purity

  Pure. No process state, no clock, no database. Every test of it runs
  `async: true`.
  """

  @doc """
  A stable hex digest of `fields` read from a row or an attribute map.

  Missing keys hash as `nil`, so an attribute map that omits an optional field
  and a row whose column is NULL produce the same digest.
  """
  @spec fingerprint(map() | struct(), [atom()]) :: String.t()
  def fingerprint(row_or_attrs, fields) when is_list(fields) do
    digest =
      fields
      |> Map.new(fn field -> {field, Map.get(row_or_attrs, field)} end)
      |> canonical_term()
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))

    Base.encode16(digest, case: :lower)
  end

  @doc """
  True when the stored row no longer matches the fingerprint stamped on it.

  A row carrying no fingerprint is diverged; see the moduledoc for why that is
  the safe direction.
  """
  @spec diverged?(map() | struct(), [atom()]) :: boolean()
  def diverged?(row, fields) when is_list(fields) do
    case Map.get(row, :template_fingerprint) do
      nil -> true
      stored -> fingerprint(row, fields) != stored
    end
  end

  @doc """
  True when the row's seeder-owned fields already equal the shipped template's.

  This is the "pristine" test: a row that matches the template exactly can be
  stamped as managed without changing a single byte of its content.
  """
  @spec matches_template?(map() | struct(), map(), [atom()]) :: boolean()
  def matches_template?(row, attrs, fields) when is_list(fields) do
    fingerprint(row, fields) == fingerprint(attrs, fields)
  end

  # Canonical form for fingerprinting: sorted key/value pairs with atoms
  # stringified, so a template map hashes identically to its jsonb round-trip.
  defp canonical_term(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical_term(value)} end)
    |> Enum.sort()
  end

  defp canonical_term(list) when is_list(list), do: Enum.map(list, &canonical_term/1)
  defp canonical_term(value) when is_boolean(value) or is_nil(value), do: value
  defp canonical_term(value) when is_atom(value), do: to_string(value)
  defp canonical_term(value), do: value
end
