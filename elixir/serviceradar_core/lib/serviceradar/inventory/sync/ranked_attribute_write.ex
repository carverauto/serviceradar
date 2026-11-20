defmodule ServiceRadar.Inventory.Sync.RankedAttributeWrite do
  @moduledoc """
  The ranked write for a writer that updates one existing device directly rather
  than through the sync upsert (the camera inventory, the mapper's role
  heuristic).

  It applies the same decision as the sync upsert's ON CONFLICT update
  (`platform.sr_attribute_write_accepted/4`, see `AttributeStrength`), in one
  UPDATE so a concurrent writer cannot race a read-then-write: each group the
  write tags is accepted or rejected as a whole against the stored row's recorded
  strength, an accepted group keeps the stored value of a field the write does
  not carry, and the accepted tags are recorded. `management_device_id` is
  written exactly, so a tagged `nil` is a recorded clear. Manual type ownership
  keeps type, type_id and the role keys.

  `attrs` may carry `:name`, `:hostname`, `:vendor_name`, `:model`, `:type`,
  `:type_id`, `:type_metadata` (role keys merged into metadata with the type
  group) and `:management_device_id`; `provenance` maps each group the write
  carries to its `AttributeStrength.tag/3`.
  """

  alias ServiceRadar.Repo

  # Manual type ownership (the sync upsert's guard, with no incoming manual write)
  # keeps type, type_id and the role keys; otherwise the type group's rank decides.
  @type_accepted_sql """
  (NOT (COALESCE(d.metadata->'type_manually_set' = 'true'::jsonb,
                 'manual' = ANY(COALESCE(d.discovery_sources, ARRAY[]::text[])))
        AND lower(COALESCE(NULLIF(btrim(d.type), ''), 'unknown')) <> 'unknown')
   AND platform.sr_attribute_write_accepted(d.attribute_provenance, $2::jsonb, 'type',
         NULLIF(btrim(d.type), '') IS NOT NULL OR NULLIF(btrim(d.metadata->>'device_role'), '') IS NOT NULL))
  """

  @sql """
  UPDATE platform.ocsf_devices AS d
  SET name =
        CASE WHEN platform.sr_attribute_write_accepted(d.attribute_provenance, $2::jsonb, 'name',
                    NULLIF(btrim(d.name), '') IS NOT NULL OR NULLIF(btrim(d.hostname), '') IS NOT NULL)
          THEN COALESCE(NULLIF($3::text, ''), d.name) ELSE d.name END,
      hostname =
        CASE WHEN platform.sr_attribute_write_accepted(d.attribute_provenance, $2::jsonb, 'name',
                    NULLIF(btrim(d.name), '') IS NOT NULL OR NULLIF(btrim(d.hostname), '') IS NOT NULL)
          THEN COALESCE(NULLIF($4::text, ''), d.hostname) ELSE d.hostname END,
      vendor_name =
        CASE WHEN platform.sr_attribute_write_accepted(d.attribute_provenance, $2::jsonb, 'vendor',
                    NULLIF(btrim(d.vendor_name), '') IS NOT NULL OR NULLIF(btrim(d.model), '') IS NOT NULL)
          THEN COALESCE(NULLIF($5::text, ''), d.vendor_name) ELSE d.vendor_name END,
      model =
        CASE WHEN platform.sr_attribute_write_accepted(d.attribute_provenance, $2::jsonb, 'vendor',
                    NULLIF(btrim(d.vendor_name), '') IS NOT NULL OR NULLIF(btrim(d.model), '') IS NOT NULL)
          THEN COALESCE(NULLIF($6::text, ''), d.model) ELSE d.model END,
      type =
        CASE WHEN #{@type_accepted_sql}
          THEN COALESCE(NULLIF($7::text, ''), d.type) ELSE d.type END,
      type_id =
        CASE WHEN #{@type_accepted_sql} AND COALESCE($8::integer, 0) > 0
          THEN $8::integer ELSE d.type_id END,
      metadata =
        CASE WHEN #{@type_accepted_sql}
          THEN COALESCE(d.metadata, '{}'::jsonb) || COALESCE($9::jsonb, '{}'::jsonb)
          ELSE d.metadata END,
      management_device_id =
        CASE WHEN platform.sr_attribute_write_accepted(d.attribute_provenance, $2::jsonb,
                    'management_device_id', d.management_device_id IS NOT NULL)
          THEN $10::text ELSE d.management_device_id END,
      attribute_provenance =
        COALESCE(d.attribute_provenance, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
          'name',
          CASE WHEN platform.sr_attribute_write_accepted(d.attribute_provenance, $2::jsonb, 'name',
                      NULLIF(btrim(d.name), '') IS NOT NULL OR NULLIF(btrim(d.hostname), '') IS NOT NULL)
            THEN $2::jsonb -> 'name' END,
          'vendor',
          CASE WHEN platform.sr_attribute_write_accepted(d.attribute_provenance, $2::jsonb, 'vendor',
                      NULLIF(btrim(d.vendor_name), '') IS NOT NULL OR NULLIF(btrim(d.model), '') IS NOT NULL)
            THEN $2::jsonb -> 'vendor' END,
          'type',
          CASE WHEN #{@type_accepted_sql} THEN $2::jsonb -> 'type' END,
          'management_device_id',
          CASE WHEN platform.sr_attribute_write_accepted(d.attribute_provenance, $2::jsonb,
                      'management_device_id', d.management_device_id IS NOT NULL)
            THEN $2::jsonb -> 'management_device_id' END
        )),
      modified_time = timezone('utc', now())
  WHERE d.uid = $1
  """

  @doc "Applies a ranked write to device `uid`. Returns `:ok` or `{:error, reason}`."
  @spec write(String.t(), map(), map()) :: :ok | {:error, term()}
  def write(_uid, _attrs, provenance) when provenance == %{}, do: :ok

  def write(uid, attrs, provenance)
      when is_binary(uid) and is_map(attrs) and is_map(provenance) do
    params = [
      uid,
      provenance,
      Map.get(attrs, :name),
      Map.get(attrs, :hostname),
      Map.get(attrs, :vendor_name),
      Map.get(attrs, :model),
      Map.get(attrs, :type),
      Map.get(attrs, :type_id),
      Map.get(attrs, :type_metadata),
      Map.get(attrs, :management_device_id)
    ]

    case Repo.query(@sql, params) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
