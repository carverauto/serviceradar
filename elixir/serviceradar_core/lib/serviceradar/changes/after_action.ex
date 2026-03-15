defmodule ServiceRadar.Changes.AfterAction do
  @moduledoc false

  @spec after_action(Ash.Changeset.t(), (term() -> term())) :: Ash.Changeset.t()
  def after_action(changeset, callback) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      run(record, callback)
    end)
  end

  @spec run(term(), (term() -> term())) :: {:ok, term()}
  def run(record, callback) do
    callback.(record)
    {:ok, record}
  end
end
