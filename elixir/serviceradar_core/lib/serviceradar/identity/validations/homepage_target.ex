defmodule ServiceRadar.Identity.Validations.HomepageTarget do
  @moduledoc """
  Rejects a `:homepage` argument that is malformed or, for a dashboard
  homepage, points at a dashboard the saving actor cannot open
  (`add-configurable-default-homepage`, D4).

  The target is read as the actor, through the dashboard resources' own read
  policies, so "cannot read" covers deleted, archived, disabled and
  not-shared-with-you alike.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Identity.Homepage

  @impl true
  def validate(changeset, _opts, context) do
    case Homepage.normalize(Ash.Changeset.get_argument(changeset, :homepage)) do
      {:ok, homepage} -> validate_target(homepage, context)
      {:error, message} -> {:error, field: :homepage, message: message}
    end
  end

  @impl true
  def atomic(changeset, opts, context) do
    case validate(changeset, opts, context) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp validate_target(homepage, context) do
    if Homepage.dashboard?(homepage) do
      case Homepage.load_target(homepage, actor: context_actor(context)) do
        {:ok, _target} -> :ok
        :error -> {:error, field: :homepage, message: "points at a dashboard you cannot open"}
      end
    else
      :ok
    end
  end

  defp context_actor(%{actor: actor}), do: actor
  defp context_actor(_context), do: nil
end
