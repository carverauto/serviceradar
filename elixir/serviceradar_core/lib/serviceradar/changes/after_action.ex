defmodule ServiceRadar.Changes.AfterAction do
  @moduledoc false

  @spec after_action(Ash.Changeset.t(), (term() -> term())) :: Ash.Changeset.t()
  def after_action(changeset, callback) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      run(record, callback)
    end)
  end

  @spec after_action_result(Ash.Changeset.t(), (term() -> :ok | {:ok, term()} | {:error, term()})) ::
          Ash.Changeset.t()
  def after_action_result(changeset, callback) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      run_result(record, callback)
    end)
  end

  @spec run(term(), (term() -> term())) :: {:ok, term()}
  def run(record, callback) do
    callback.(record)
    {:ok, record}
  end

  @spec run_result(term(), (term() -> :ok | {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def run_result(record, callback) do
    case callback.(record) do
      :ok -> {:ok, record}
      {:ok, _value} -> {:ok, record}
      {:error, reason} -> {:error, reason}
    end
  end
end
