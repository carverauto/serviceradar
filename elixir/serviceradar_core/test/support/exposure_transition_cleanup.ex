defmodule ServiceRadar.TestSupport.ExposureTransitionCleanup do
  @moduledoc """
  Deletes the rows the exposure transition triggers write for a device: its
  outbox rows, its fact watermarks, and the package, package-version and
  advisory ordinals allocated for its keys.

  An unboxed test that commits an actionable assessment (or deletes one) leaves
  these behind; call this in `on_exit` after deleting the assessments.
  """

  import Ecto.Query

  alias ServiceRadar.Repo

  @spec delete_for_devices!([String.t()]) :: :ok
  def delete_for_devices!(device_uids) when is_list(device_uids) do
    keys =
      Repo.all(
        from(o in "exposure_transition_outbox",
          where: o.device_uid in ^device_uids,
          select: {
            fragment("? ->> 'package_identity_key'", o.payload),
            fragment("? ->> 'cve_id'", o.payload)
          }
        ),
        prefix: "platform"
      ) ++
        Repo.all(
          from(w in "exposure_fact_watermarks",
            where: w.device_uid in ^device_uids,
            select: {w.package_identity_key, w.cve_id}
          ),
          prefix: "platform"
        )

    package_keys = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    cve_ids = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    for table <- ["exposure_dimension_outbox", "exposure_dimension_state"] do
      Repo.delete_all(
        from(row in table,
          where:
            fragment("?->>'package_identity_key'", row.payload) in ^package_keys or
              fragment("?->>'cve_id'", row.payload) in ^cve_ids
        ),
        prefix: "platform"
      )
    end

    for {table, column, values} <- [
          {"exposure_package_ordinals", :package_identity_key, package_keys},
          {"exposure_package_version_ordinals", :package_identity_key, package_keys},
          {"exposure_advisory_ordinals", :advisory_id, cve_ids},
          {"exposure_transition_outbox", :device_uid, device_uids},
          {"exposure_fact_watermarks", :device_uid, device_uids}
        ] do
      Repo.delete_all(from(row in table, where: field(row, ^column) in ^values),
        prefix: "platform"
      )
    end

    :ok
  end
end
