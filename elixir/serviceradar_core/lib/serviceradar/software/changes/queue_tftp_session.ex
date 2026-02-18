defmodule ServiceRadar.Software.Changes.QueueTftpSession do
  @moduledoc """
  Queues a newly created TFTP session by invoking the `:queue` state transition.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      queue_opts =
        [actor: get_actor(changeset)]
        |> maybe_put_scope(get_scope(changeset))

      record
      |> Ash.Changeset.for_update(:queue, %{}, queue_opts)
      |> Ash.update(queue_opts)
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :not_atomic

  defp get_actor(%Ash.Changeset{context: %{private: %{actor: actor}}}), do: actor
  defp get_actor(%Ash.Changeset{context: %{actor: actor}}), do: actor
  defp get_actor(_), do: nil

  defp get_scope(%Ash.Changeset{context: %{private: %{scope: scope}}}), do: scope
  defp get_scope(%Ash.Changeset{context: %{scope: scope}}), do: scope
  defp get_scope(_), do: nil

  defp maybe_put_scope(opts, nil), do: opts
  defp maybe_put_scope(opts, scope), do: Keyword.put(opts, :scope, scope)
end
