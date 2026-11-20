defmodule ServiceRadar.Edge.Changes.PublishOnboardingEvent do
  @moduledoc """
  Ash change that mirrors edge onboarding events into OCSF.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Changes.AfterAction
  alias ServiceRadar.Events.OnboardingWriter

  @impl true
  def change(changeset, _opts, _context) do
    AfterAction.after_action(changeset, &OnboardingWriter.write/1)
  end

  @impl true
  # An atomic update never calls change/3, so the hook is registered here too.
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
