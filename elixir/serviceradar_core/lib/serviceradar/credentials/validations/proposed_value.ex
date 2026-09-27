defmodule ServiceRadar.Credentials.Validations.ProposedValue do
  @moduledoc false

  # Reads the value an atomic update will write to one attribute.
  #
  # An atomic changeset carries no original record, so a validation cannot fall
  # back to `Ash.Changeset.get_attribute/2`. The proposed value is either a cast
  # literal in `attributes` (a bulk update given plain input) or an entry in
  # `atomics` (a single-record update upgraded to an atomic one, which carries
  # its already-cast literals there). An entry that is an expression has no
  # value until the database evaluates it, so it cannot be checked here.

  @type t :: :unchanged | {:changed, term()} | {:not_atomic, String.t()}

  @spec fetch(Ash.Changeset.t(), atom()) :: t()
  def fetch(changeset, field) do
    case Ash.Changeset.fetch_change(changeset, field) do
      {:ok, value} -> {:changed, value}
      :error -> fetch_atomic(changeset, field)
    end
  end

  defp fetch_atomic(changeset, field) do
    case Keyword.fetch(changeset.atomics, field) do
      :error ->
        :unchanged

      {:ok, value} ->
        if Ash.Expr.expr?(value) do
          {:not_atomic, "#{field} is set by an expression, so its value cannot be validated"}
        else
          {:changed, value}
        end
    end
  end
end
