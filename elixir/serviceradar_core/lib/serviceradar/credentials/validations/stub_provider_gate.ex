defmodule ServiceRadar.Credentials.Validations.StubProviderGate do
  @moduledoc """
  Refuses a `:stub` secret provider unless the stub adapter is enabled.

  The stub adapter returns plaintext from unencrypted provider metadata, so it
  exists for tests only. Outside tests the gate
  (`ServiceRadar.Credentials.SecretProviderAdapters.Stub.enabled?/0`) is off and
  no create or update may leave a provider with `provider_type: :stub`.
  """

  use Ash.Resource.Validation

  import Ash.Expr

  alias Ash.Error.Changes.InvalidAttribute
  alias ServiceRadar.Credentials.SecretProviderAdapters.Stub

  @message "stub is a test-only provider type and is disabled in this environment"

  @impl true
  def validate(changeset, _opts, _context) do
    if Stub.enabled?() or Ash.Changeset.get_attribute(changeset, :provider_type) != :stub do
      :ok
    else
      {:error, field: :provider_type, value: :stub, message: @message}
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    if Stub.enabled?() do
      :ok
    else
      {:atomic, [:provider_type], expr(^atomic_ref(:provider_type) == :stub),
       expr(
         error(^InvalidAttribute, %{
           field: :provider_type,
           value: ^atomic_ref(:provider_type),
           message: ^@message
         })
       )}
    end
  end
end
