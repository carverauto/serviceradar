defmodule ServiceRadar.Changes.DispatchAgentCommand do
  @moduledoc false

  alias ServiceRadar.AshContext

  @spec after_action(Ash.Changeset.t(), (term(), keyword() -> {:ok, term()} | {:error, term()})) ::
          Ash.Changeset.t()
  def after_action(changeset, dispatch_fun) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      run(record, AshContext.actor(changeset), dispatch_fun)
    end)
  end

  @spec run(term(), term(), (term(), keyword() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def run(record, actor, dispatch_fun) do
    case dispatch_fun.(record, actor: actor) do
      {:ok, _command_id} -> {:ok, record}
      {:error, reason} -> {:error, reason}
    end
  end
end
