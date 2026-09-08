defmodule ServiceRadar.Dashboards.Validations.NextDueAdvances do
  @moduledoc """
  Ensures report scanner state transitions move the schedule forward.
  """

  use Ash.Resource.Validation

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    due_at = Ash.Changeset.get_argument(changeset, :due_at)
    next_due_at = Ash.Changeset.get_attribute(changeset, :next_due_at)

    if match?(%DateTime{}, due_at) and match?(%DateTime{}, next_due_at) and
         DateTime.after?(next_due_at, due_at) do
      :ok
    else
      {:error, field: :next_due_at, message: "must be after due_at"}
    end
  end
end
