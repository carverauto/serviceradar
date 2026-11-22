defmodule ServiceRadar.Monitoring.Validations.NetperfProfileOmitDuration do
  @moduledoc """
  Validates that `omit_sec < duration_sec` on `ServiceRadar.Monitoring.NetperfProfile`
  create and update changesets, including atomic updates.
  """

  use Ash.Resource.Validation

  import Ash.Expr

  alias Ash.Error.Changes.InvalidAttribute
  alias ServiceRadar.Validations.ProposedValue

  @message "must be strictly less than duration_sec"

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    omit_sec = Ash.Changeset.get_attribute(changeset, :omit_sec)
    duration_sec = Ash.Changeset.get_attribute(changeset, :duration_sec)

    if is_integer(omit_sec) and is_integer(duration_sec) and omit_sec >= duration_sec do
      {:error, field: :omit_sec, value: omit_sec, message: @message}
    else
      :ok
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    if ProposedValue.fetch(changeset, :omit_sec) == :unchanged and
         ProposedValue.fetch(changeset, :duration_sec) == :unchanged do
      :ok
    else
      {:atomic, [:omit_sec, :duration_sec],
       expr(^atomic_ref(:omit_sec) >= ^atomic_ref(:duration_sec)),
       expr(
         error(^InvalidAttribute, %{
           field: :omit_sec,
           value: ^atomic_ref(:omit_sec),
           message: ^@message
         })
       )}
    end
  end
end
