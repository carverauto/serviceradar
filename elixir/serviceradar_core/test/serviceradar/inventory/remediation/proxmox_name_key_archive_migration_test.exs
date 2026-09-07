defmodule ServiceRadar.Inventory.Remediation.ProxmoxNameKeyArchiveMigrationTest do
  @moduledoc """
  Pins the GitHub #4051 archive migration: the gen-1 bare-name family is
  archived (never deleted outright), still-minted fallbacks are left alone,
  and the down migration stays irreversible like the link-local alias archive.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Repo.Migrations.ArchiveProxmoxNameKeyedIdentifiers, as: Migration

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260906150000_archive_proxmox_name_keyed_identifiers.exs",
                    __DIR__
                  )
  @external_resource @migration_path

  Code.require_file(@migration_path)

  test "predicate covers the gen-1 bare-name family" do
    predicate = Migration.ambiguous_predicate("identifier_value")

    assert predicate =~ "proxmox:(vm|container)"
    assert predicate =~ "proxmox:hypervisor"
    # plain vmid placeholders are scoped, never archived
    assert predicate =~ "!~ '^[0-9]+$'"
  end

  test "predicate leaves still-minted fallbacks alone" do
    predicate = Migration.ambiguous_predicate("identifier_value")

    refute predicate =~ "proxmox:node"
    refute predicate =~ "proxmox:pve"
  end

  test "migration archives with provenance and scrubs metadata bridges" do
    migration = File.read!(@migration_path)

    assert migration =~ "device_identifier_archive"
    assert migration =~ "proxmox_name_keyed_github_4051"
    assert migration =~ "legacy_integration_ids"
    assert migration =~ "cannot restore archived Proxmox name-keyed identifiers"
  end
end
