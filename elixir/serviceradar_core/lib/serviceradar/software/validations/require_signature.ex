defmodule ServiceRadar.Software.Validations.RequireSignature do
  @moduledoc """
  Validates that a software image has signature metadata when
  `SOFTWARE_REQUIRE_SIGNED_IMAGES` is enabled.

  Only blocks activation — upload and verify are unaffected so operators
  can still stage unsigned images for testing.
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    if require_signed_images?() do
      signature = Ash.Changeset.get_attribute(changeset, :signature)

      if valid_signature?(signature) do
        :ok
      else
        {:error,
         field: :signature,
         message: "Signature metadata is required to activate images (SOFTWARE_REQUIRE_SIGNED_IMAGES=true)"}
      end
    else
      :ok
    end
  end

  defp require_signed_images? do
    Application.get_env(:serviceradar_core, :require_signed_images, false)
  end

  defp valid_signature?(nil), do: false
  defp valid_signature?(sig) when sig == %{}, do: false
  defp valid_signature?(%{} = _sig), do: true
  defp valid_signature?(_), do: false
end
