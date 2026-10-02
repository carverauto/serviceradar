defmodule ServiceRadar.TestSupport.IdentifierArchiveFixtures do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Repo

  # Moves one held identifier into the archive the way a retirement pass does
  # (ServiceRadar.Inventory.Identity.SourceRetirement), without the collections a pass needs:
  # for tests about what a retired identifier decides, not about when one retires.
  @archive_sql """
  WITH moved AS (
    DELETE FROM platform.device_identifiers
    WHERE identifier_type = $1::text AND identifier_value = $2::text AND partition = $3::text
    RETURNING *
  )
  INSERT INTO platform.device_identifier_archive
    (id, device_id, identifier_type, identifier_value, partition, confidence, source,
     first_seen, last_seen, verified, metadata, archived_at, archive_reason)
  SELECT id, device_id, identifier_type::text, identifier_value,
         COALESCE(partition, 'default'), confidence::text, source,
         first_seen AT TIME ZONE 'UTC', last_seen AT TIME ZONE 'UTC',
         COALESCE(verified, false), COALESCE(metadata, '{}'::jsonb), now(), 'source_absent'
  FROM moved
  """

  @spec archive!(atom(), String.t(), String.t()) :: :ok
  def archive!(type, value, partition \\ "default") do
    %{num_rows: 1} = Repo.query!(@archive_sql, [Atom.to_string(type), value, partition])
    :ok
  end

  @spec archive_owner(atom(), String.t()) :: String.t() | nil
  def archive_owner(type, value) do
    Repo.one(
      from(archived in "device_identifier_archive",
        where:
          archived.identifier_type == ^Atom.to_string(type) and
            archived.identifier_value == ^value,
        select: archived.device_id
      ),
      prefix: "platform"
    )
  end
end
