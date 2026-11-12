defmodule ServiceRadar.Inventory.Changes.ReleaseContestedAddress do
  @moduledoc """
  A restore never brings back an address another live device of the partition holds.

  A tombstone keeps the address it held when it was deleted (a merge tombstones the merged-away
  record through `:soft_delete` without clearing it), and by the time it is restored another
  live device may hold that address: the merge survivor, an earlier record of the same unmerge
  chain, or the next holder of a DHCP lease. Restoring the stored value would put two live rows
  on one address, `ocsf_devices_unique_active_ip_idx` would refuse the write, and the restore
  would fail as a whole. So the stored address is cleared in the same UPDATE that clears the
  tombstone, judged against the rows that statement sees.

  A caller that sets `ip` itself keeps its value: it chose the address, and the index decides.

  The cleared address is not recorded on the device. A caller that must keep it discoverable
  records it with its own transition (the unmerge audit's `withheld_ips`, a reactivation
  decision's `cleared_ip`); `MergeAudit`'s `from_device_ip` keeps the address a merge saw.

  Rows restored together by one bulk statement are judged against the rows as they stood
  before it, so two tombstones sharing an address that no live device holds are both restored
  with it, and the index refuses the statement.
  """

  use Ash.Resource.Change

  import Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :ip) do
      changeset
    else
      Ash.Changeset.atomic_update(changeset, :ip, uncontested_ip())
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :ip) do
      :ok
    else
      {:atomic, %{ip: uncontested_ip()}}
    end
  end

  # Plain references read the row as it stands before the update: the tombstone being restored.
  defp uncontested_ip do
    expr(
      fragment(
        """
        CASE WHEN EXISTS (
          SELECT 1 FROM platform.ocsf_devices AS holder
          WHERE holder.deleted_at IS NULL AND holder.partition = ? AND holder.ip = ?
            AND holder.uid <> ?
        ) THEN NULL ELSE ? END
        """,
        partition,
        ip,
        uid,
        ip
      )
    )
  end
end
