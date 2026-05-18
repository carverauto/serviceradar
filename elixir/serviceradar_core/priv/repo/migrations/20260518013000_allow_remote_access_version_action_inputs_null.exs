defmodule ServiceRadar.Repo.Migrations.AllowRemoteAccessVersionActionInputsNull do
  @moduledoc """
  Stops remote-access PaperTrail version rows from retaining action inputs.

  Remote-access request/session action inputs can contain durable approval,
  credential-rule, and metadata pointers. The resources now disable action
  input storage, so these columns must allow NULL. Existing values are scrubbed
  to remove previously retained pointers.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    scrub_action_inputs(:remote_access_request_versions)
    scrub_action_inputs(:remote_access_session_versions)

    execute("""
    ALTER TABLE #{@prefix}.remote_access_request_versions
    ALTER COLUMN version_action_inputs DROP NOT NULL
    """)

    execute("""
    ALTER TABLE #{@prefix}.remote_access_session_versions
    ALTER COLUMN version_action_inputs DROP NOT NULL
    """)
  end

  def down do
    scrub_action_inputs(:remote_access_request_versions)
    scrub_action_inputs(:remote_access_session_versions)

    execute("""
    ALTER TABLE #{@prefix}.remote_access_request_versions
    ALTER COLUMN version_action_inputs SET NOT NULL
    """)

    execute("""
    ALTER TABLE #{@prefix}.remote_access_session_versions
    ALTER COLUMN version_action_inputs SET NOT NULL
    """)
  end

  defp scrub_action_inputs(table) do
    execute("""
    UPDATE #{@prefix}.#{table}
    SET version_action_inputs = '{}'::jsonb
    WHERE version_action_inputs IS DISTINCT FROM '{}'::jsonb
    """)
  end
end
