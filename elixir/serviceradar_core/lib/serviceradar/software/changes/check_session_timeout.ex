defmodule ServiceRadar.Software.Changes.CheckSessionTimeout do
  @moduledoc """
  Validates that a session has actually exceeded its timeout_seconds before
  allowing the expire transition.

  The AshOban trigger's read action uses a coarse 1-minute filter.
  This change performs the precise per-session check.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    record = changeset.data
    timeout = record.timeout_seconds || 300
    updated_at = record.updated_at

    if updated_at &&
         DateTime.diff(DateTime.utc_now(), updated_at, :second) >= timeout do
      changeset
    else
      Ash.Changeset.add_error(changeset, field: :status, message: "session has not timed out yet")
    end
  end
end
