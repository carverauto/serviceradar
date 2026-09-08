defmodule ServiceRadar.Plugins.Validations.RepositorySource do
  @moduledoc """
  Validates a `PluginRepository`'s source URL and its trusted signing key.

  Both checks belong at write time rather than import time. A repository whose
  URL cannot be parsed, or whose public key is not a usable ed25519 key, is not
  a weaker source -- it is one that can never import anything. Rejecting it here
  puts the failure in front of the admin filling in the form, instead of in an
  Oban job days later where it reads as "the catalog is empty".
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias ServiceRadar.Plugins.RepoUrl

  @ed25519_key_bytes 32

  @impl true
  def init(opts), do: {:ok, opts}

  # Both checks read only submitted values, so the same code is correct in the
  # atomic path -- there is no stored data to load and no reason to force the
  # action non-atomic.
  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- validate_repo_url(changeset) do
      validate_public_key(changeset)
    end
  end

  defp validate_repo_url(changeset) do
    case Ash.Changeset.fetch_change(changeset, :repo_url) do
      # Not being changed: an update that leaves the URL alone must not have to
      # restate it.
      :error ->
        :ok

      {:ok, value} ->
        case RepoUrl.parse(value) do
          {:ok, _parsed} ->
            :ok

          {:error, reason} ->
            {:error,
             InvalidAttribute.exception(
               field: :repo_url,
               message: RepoUrl.describe_error(reason)
             )}
        end
    end
  end

  defp validate_public_key(changeset) do
    case Ash.Changeset.fetch_change(changeset, :signing_public_key) do
      :error ->
        :ok

      {:ok, value} ->
        case decode_ed25519(value) do
          :ok ->
            :ok

          {:error, message} ->
            {:error,
             InvalidAttribute.exception(
               field: :signing_public_key,
               message: message
             )}
        end
    end
  end

  # The publisher-side tool emits standard base64 (see
  # build/wasm_plugins/upload_signature_tool.go), and `UploadSignature`
  # verifies against a raw 32-byte key. Anything else would fail every
  # signature check with `:invalid_signature`, which says nothing about the key
  # being the problem.
  defp decode_ed25519(value) when is_binary(value) do
    case Base.decode64(String.trim(value)) do
      {:ok, decoded} when byte_size(decoded) == @ed25519_key_bytes ->
        :ok

      {:ok, decoded} ->
        {:error, "must be a 32-byte ed25519 public key; decoded to #{byte_size(decoded)} bytes"}

      :error ->
        {:error, "must be base64-encoded"}
    end
  end

  defp decode_ed25519(_value), do: {:error, "is required"}
end
