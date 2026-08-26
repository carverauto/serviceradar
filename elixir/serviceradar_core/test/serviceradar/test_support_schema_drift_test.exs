defmodule ServiceRadar.TestSupportSchemaDriftTest do
  @moduledoc """
  Regression for the 2026-08-25 shared-template drift incident.

  staging's `20260825030000_rekey_discovered_interfaces_current_state` rekeyed
  `discovered_interfaces`. `sr_core_template` is shared across branches and only ratchets
  forward, so every branch cut before that migration cloned the rekeyed schema and ran its own
  three-column `Inventory.Interface` identity against it. `mix ecto.migrate` reported
  "Migrations already up" -- correctly, since a behind-branch has nothing PENDING -- and the
  failure surfaced as 15 `42P10 invalid_column_reference` errors across four unrelated test
  files, naming no migration.

  The direction is the whole point: EXTRA APPLIED is the silent case worth failing on, PENDING
  is the loud case Ecto already handles.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.TestSupport

  # The real versions from the incident, so the test is anchored to what actually happened.
  @on_disk ~w(20260117080000 20260821180000)
  @rekey "20260825030000"

  describe "a database AHEAD of the checkout is refused" do
    test "raises and names the extra applied versions" do
      error =
        assert_raise ArgumentError, fn ->
          TestSupport.assert_migrations_not_ahead!(@on_disk ++ [@rekey], @on_disk)
        end

      # Naming the version is the entire value over the 42P10 scatter it replaces: without it
      # the message would say drift exists but not which migration to rebase onto.
      assert error.message =~ @rekey
      assert error.message =~ "AHEAD of this checkout"
    end

    test "reports every extra version, not just the first" do
      extra = [@rekey, "20260825031000"]

      error =
        assert_raise ArgumentError, fn ->
          TestSupport.assert_migrations_not_ahead!(@on_disk ++ extra, @on_disk)
        end

      for version <- extra do
        assert error.message =~ version, "#{version} missing from the failure message"
      end

      assert error.message =~ "2 migration(s)"
    end
  end

  describe "the cases that must NOT fail" do
    test "an exactly matching database passes" do
      assert :ok = TestSupport.assert_migrations_not_ahead!(@on_disk, @on_disk)
    end

    test "a database BEHIND the checkout passes -- pending is Ecto's job, not this guard's" do
      # Inverting the incident: the branch has a migration the database has not applied. That is
      # the ordinary first-run case, and failing it here would turn every fresh provision into a
      # hard stop. A guard that fired in both directions would be indistinguishable from one
      # that simply demanded equality.
      assert :ok = TestSupport.assert_migrations_not_ahead!(@on_disk, @on_disk ++ [@rekey])
    end

    test "order and duplicates do not matter" do
      assert :ok =
               TestSupport.assert_migrations_not_ahead!(
                 Enum.reverse(@on_disk),
                 @on_disk ++ @on_disk
               )
    end
  end

  describe "an empty on-disk list is a packaging fault, not drift" do
    test "raises about migrations not being staged rather than blaming the database" do
      # Without this branch every applied version reads as "extra" and the guard would blame the
      # database for what is really priv/repo/migrations missing from the runfiles tree.
      error =
        assert_raise ArgumentError, fn ->
          TestSupport.assert_migrations_not_ahead!(@on_disk, [])
        end

      assert error.message =~ "no migration files were found on disk"
      refute error.message =~ "AHEAD of this checkout"
    end
  end
end
