defmodule ServiceRadar.Credentials.Changes.WriteProviderLifecycleEvent do
  @moduledoc false

  use Ash.Resource.Change

  alias ServiceRadar.Changes.AfterAction
  alias ServiceRadar.Credentials.CredentialEventWriter

  @impl true
  def init(opts) do
    {:ok, action: Keyword.fetch!(opts, :action)}
  end

  @impl true
  def change(changeset, opts, _context) do
    AfterAction.after_action(
      changeset,
      &CredentialEventWriter.write_provider_lifecycle(&1, opts[:action])
    )
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
