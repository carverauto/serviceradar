defmodule ServiceRadar.Inventory.Remediation.DireRemediationStepsTest do
  @moduledoc """
  Pure (no-DB) coverage for the armis-overmerge guard on the DIRE remediation
  step order: `armis-dups` (the re-collapse vector that merges every device
  sharing one armis_device_id onto a single canonical) is excluded from the
  default run order and is refused even via an explicit `steps:` request,
  unless config opts it back in.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.Remediation.DireRemediation

  setup do
    original = Application.get_env(:serviceradar_core, DireRemediation)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:serviceradar_core, DireRemediation)
        value -> Application.put_env(:serviceradar_core, DireRemediation, value)
      end
    end)

    :ok
  end

  defp set_enable_armis_dups(value) do
    put_remediation_config(:enable_armis_dups, value)
  end

  defp set_enable_armis_unmerge_execute(value) do
    put_remediation_config(:enable_armis_unmerge_execute, value)
  end

  defp put_remediation_config(key, value) do
    config = Application.get_env(:serviceradar_core, DireRemediation, [])
    Application.put_env(:serviceradar_core, DireRemediation, Keyword.put(config, key, value))
  end

  test "armis-dups is excluded from the default step order" do
    Application.delete_env(:serviceradar_core, DireRemediation)
    refute "armis-dups" in DireRemediation.steps()
    # The safe steps remain present.
    assert "blob-purge" in DireRemediation.steps()
    assert "proxmox-dups" in DireRemediation.steps()
    assert "link-local-alias-archive" in DireRemediation.steps()
  end

  test "link-local-alias-archive runs before any step that can merge" do
    Application.delete_env(:serviceradar_core, DireRemediation)
    steps = DireRemediation.steps()
    ll = Enum.find_index(steps, &(&1 == "link-local-alias-archive"))
    al = Enum.find_index(steps, &(&1 == "agent-links"))
    px = Enum.find_index(steps, &(&1 == "proxmox-dups"))

    assert is_integer(ll)
    assert ll < al
    assert ll < px
  end

  test "armis-dups is included only when config opts it back in" do
    set_enable_armis_dups(true)
    assert "armis-dups" in DireRemediation.steps()

    set_enable_armis_dups(false)
    refute "armis-dups" in DireRemediation.steps()
  end

  test "explicitly requesting armis-dups is refused while disabled (no steps run)" do
    set_enable_armis_dups(false)

    # resolve_steps/1 rejects before any step executes or any DB is touched.
    assert {:error, {:disabled_steps, ["armis-dups"]}} =
             DireRemediation.run(steps: ["armis-dups"], mode: :dry_run)
  end

  test "unknown steps are still rejected" do
    assert {:error, {:unknown_steps, ["nope"]}} =
             DireRemediation.run(steps: ["nope"], mode: :dry_run)
  end

  test "all cannot be mixed with another step" do
    assert {:error, {:mixed_all_steps, ["all", "armis-unmerge"]}} =
             DireRemediation.run(steps: ["all", "armis-unmerge"], mode: :dry_run)
  end

  test "armis-unmerge is dormant: excluded from the default order in every config state" do
    # The disposition step only runs when an operator explicitly requests
    # `steps: ["armis-unmerge"]` (covered by the DB-backed step test); a default
    # `all` run never includes it — even when armis-dups is opted back in.
    Application.delete_env(:serviceradar_core, DireRemediation)
    refute "armis-unmerge" in DireRemediation.steps()

    set_enable_armis_dups(true)
    refute "armis-unmerge" in DireRemediation.steps()

    set_enable_armis_dups(false)
    refute "armis-unmerge" in DireRemediation.steps()
  end

  test "armis-unmerge dry-run is available while execute remains gated" do
    set_enable_armis_unmerge_execute(false)

    assert "armis-unmerge" in DireRemediation.available_steps(:dry_run)
    refute "armis-unmerge" in DireRemediation.available_steps(:execute)

    manifest_path =
      Path.join(
        System.tmp_dir!(),
        "blocked_armis_unmerge_#{System.unique_integer([:positive])}.ndjson"
      )

    refute File.exists?(manifest_path)

    assert {:error, {:execute_disabled, ["armis-unmerge"]}} =
             DireRemediation.run(
               steps: ["armis-unmerge"],
               mode: :execute,
               manifest_path: manifest_path,
               armis_unmerge_execute_enabled: true
             )

    refute File.exists?(manifest_path)
  end

  test "runtime signoff enables only an explicit armis-unmerge execute request" do
    set_enable_armis_unmerge_execute(true)

    assert "armis-unmerge" in DireRemediation.available_steps(:execute)
    refute "armis-unmerge" in DireRemediation.steps()
  end

  test "failure reports identify positive counters and execution blocks" do
    reports = %{
      "agent-links" => %{errors: 2, planned: 10},
      "armis-unmerge" => %{execution_blocked: true, split_failures: 0},
      "proxmox-dups" => %{merge_failures: 0}
    }

    assert DireRemediation.report_failures(reports) == %{
             "agent-links" => %{errors: 2},
             "armis-unmerge" => %{execution_blocked: true}
           }
  end
end
