defmodule ServiceRadar.SweepJobs.Changes.NormalizeStaticTargets do
  @moduledoc """
  Drops a static target that lies entirely inside another, keeps the outer
  target's text, and orders the result by address family, start address, and
  width. Refuses a target that is invalid, too wide, or overlaps another
  without containing it.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Edge.SweepPlan

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.action_type == :create or
         Ash.Changeset.changing_attribute?(changeset, :static_targets) do
      targets = Ash.Changeset.get_attribute(changeset, :static_targets) || []

      case SweepPlan.merge_static_targets(targets) do
        {:ok, merged} ->
          if merged == targets do
            changeset
          else
            Ash.Changeset.force_change_attribute(changeset, :static_targets, merged)
          end

        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: :static_targets,
            message: format_reason(reason)
          )
      end
    else
      changeset
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp format_reason({:unmergeable_targets, left, right}) do
    "overlapping static targets #{left} and #{right} cannot be merged into a single CIDR range"
  end

  defp format_reason({:target_too_wide, target}) do
    "static target #{target} is too wide (IPv6 prefixes must be /65 or narrower)"
  end

  defp format_reason({:invalid_target, target}) do
    "invalid static target #{target}"
  end
end
