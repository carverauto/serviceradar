defmodule ServiceRadar.SysmonProfiles.Validations.ValidateSampleInterval do
  @moduledoc """
  Validates that the `sample_interval` attribute is a well-formed Go-style
  duration string within the range the agent collector honors.

  Delegates to `ServiceRadar.SysmonProfiles.SampleInterval` so the accepted
  window matches the agent-side clamp bounds exactly. Few-second intervals are
  accepted (per-profile opt-in for higher-resolution sampling).
  """

  use Ash.Resource.Validation

  alias ServiceRadar.SysmonProfiles.SampleInterval

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :sample_interval) do
      nil ->
        # allow_nil? is enforced separately by the attribute definition.
        :ok

      value ->
        case SampleInterval.validate(value) do
          :ok -> :ok
          {:error, message} -> {:error, field: :sample_interval, message: message}
        end
    end
  end
end
