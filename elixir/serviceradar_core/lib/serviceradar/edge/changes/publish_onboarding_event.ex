defmodule ServiceRadar.Edge.Changes.PublishOnboardingEvent do
  @moduledoc """
  Ash change that mirrors edge onboarding events into OCSF.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Events.OnboardingWriter

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, event ->
      OnboardingWriter.write(event)
      {:ok, event}
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
