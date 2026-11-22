defmodule ServiceRadar.DeclarativeChecks.PackSeederIntegrationTest do
  @moduledoc """
  The seeder against a database holding what the earlier seeder left behind:
  the storage checks at pack version 1.0.0, one of them under a slug the pack
  files never used, with the parameter names that seeder used.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Catalog.BuiltinPacks
  alias ServiceRadar.Catalog.InstalledSolutionPack
  alias ServiceRadar.DeclarativeChecks.CanonicalJSON
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.DeclarativeChecks.Importer
  alias ServiceRadar.DeclarativeChecks.PackSeeder
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.TestSupport

  require Ash.Query

  @pack_id "io.serviceradar.storage-and-nvr-health"
  @retired_slug "storage-archive-credential-and-usage-health"
  @actor SystemActor.system(:pack_seeder_integration_test)

  # The earlier seeder's names for two of the pack's parameters.
  @earlier_names %{
    "utilization_warn_pct" => "warn_percent",
    "utilization_crit_pct" => "crit_percent"
  }

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, shipped} = BuiltinPacks.get_pack("storage-and-nvr-health")
    Enum.each(shipped.checks, &import_as_earlier_seeder(&1.normalized))
    %{shipped: shipped}
  end

  test "adopts the earlier seeder's checks, keeps tuned thresholds and leaves one alert per condition",
       %{shipped: shipped} do
    {:ok, utilization} =
      DeclarativeCheck.get_by_slug("storage-entitlement-utilization", actor: @actor)

    {:ok, _} =
      utilization
      |> Ash.Changeset.for_update(:update, %{parameter_overrides: %{"warn_percent" => 70}},
        actor: @actor
      )
      |> Ash.update(actor: @actor)

    assert rule_enabled?("declarative_check:#{@retired_slug}")
    assert rule_enabled?("declarative_check:storage-entitlement-utilization")

    assert {:ok, [%{slug: "storage-and-nvr-health", action: :installed}]} =
             PackSeeder.seed_builtin_packs()

    assert {:ok, installed} = InstalledSolutionPack.get_by_pack_id(@pack_id, actor: @actor)
    assert installed.pack_version == shipped.manifest["version"]
    assert installed.source_type == :builtin

    for slug <- Enum.map(shipped.checks, & &1.normalized["slug"]) do
      assert {:ok, check} = DeclarativeCheck.get_by_slug(slug, actor: @actor)
      assert check.managed
      assert check.pack_version == shipped.manifest["version"]
    end

    {:ok, utilization} =
      DeclarativeCheck.get_by_slug("storage-entitlement-utilization", actor: @actor)

    assert utilization.parameter_overrides == %{"utilization_warn_pct" => 70}

    # The check that lived under the old slug is gone, and so is its alert rule.
    assert {:error, _} = DeclarativeCheck.get_by_slug(@retired_slug, actor: @actor)
    assert rule("declarative_check:#{@retired_slug}") == nil

    # The pack's rule is now the alert for "storage entitlement down"; the
    # check's automatic rule no longer opens one beside it.
    assert rule_enabled?("storage_entitlement_hard_cap")
    refute rule_enabled?("declarative_check:storage-entitlement-utilization")

    assert {:ok, [%{action: :reapplied}]} = PackSeeder.seed_builtin_packs()
    assert length(pack_checks()) == length(shipped.checks)
  end

  test "a retired check the operator changed and detached is left in place" do
    {:ok, retired} = DeclarativeCheck.get_by_slug(@retired_slug, actor: @actor)
    slower = Map.put(retired.schedule, "interval_seconds", 900)

    {:ok, changed} =
      retired
      |> Ash.Changeset.for_update(:update, %{schedule: slower, confirm_detach: true},
        actor: @actor
      )
      |> Ash.update(actor: @actor)

    # Changing a managed check detaches it from its pack; it is the operator's now.
    refute changed.managed

    assert {:ok, [%{action: :installed}]} = PackSeeder.seed_builtin_packs()

    assert {:ok, kept} = DeclarativeCheck.get_by_slug(@retired_slug, actor: @actor)
    assert kept.schedule["interval_seconds"] == 900
  end

  # Rebuilds a check as the earlier seeder stored it: pack version 1.0.0, its
  # own parameter names, an automatic alert on "down", and the old slug for
  # the archive check.
  defp import_as_earlier_seeder(shipped_doc) do
    doc =
      shipped_doc
      |> Jason.encode!()
      |> rename_parameters()
      |> Jason.decode!()
      |> Map.put("pack_version", "1.0.0")
      |> Map.put("managed", true)
      |> put_in(["alert_policy", "open_on_statuses"], ["down"])
      |> Map.update!("slug", fn
        "storage-archive-credential-health" -> @retired_slug
        slug -> slug
      end)

    doc = Map.put(doc, "template_fingerprint", CanonicalJSON.template_fingerprint(doc))

    assert {:ok, %{action: :created}} =
             Importer.import_document(doc, actor: @actor, skip_srql_nif?: true)
  end

  defp rename_parameters(json) do
    Enum.reduce(@earlier_names, json, fn {current, earlier}, acc ->
      String.replace(acc, current, earlier)
    end)
  end

  defp pack_checks do
    DeclarativeCheck
    |> Ash.Query.for_read(:read, %{}, actor: @actor)
    |> Ash.Query.filter(pack_id == ^@pack_id)
    |> Ash.read!(actor: @actor)
  end

  defp rule(name) do
    StatefulAlertRule
    |> Ash.Query.for_read(:read, %{}, actor: @actor)
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(actor: @actor, domain: ServiceRadar.Observability)
  end

  defp rule_enabled?(name) do
    case rule(name) do
      nil -> false
      rule -> rule.enabled
    end
  end
end
