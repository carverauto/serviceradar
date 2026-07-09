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
    Application.put_env(:serviceradar_core, DireRemediation, enable_armis_dups: value)
  end

  test "armis-dups is excluded from the default step order" do
    Application.delete_env(:serviceradar_core, DireRemediation)
    refute "armis-dups" in DireRemediation.steps()
    # The safe steps remain present.
    assert "blob-purge" in DireRemediation.steps()
    assert "proxmox-dups" in DireRemediation.steps()
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
end
