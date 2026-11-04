defmodule ServiceRadar.Edge.IssuerKeyImportDbTest do
  @moduledoc """
  Upgrading from the file-based edge issuer key: the first store imports the file's seed, so
  the public key is unchanged and signatures made before the import keep verifying.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.IssuerKey
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.EdgeSourceClaimsV1
  alias ServiceRadar.Repo

  @moduletag :integration
  @moduletag :tmp_dir

  # Invented for this test.
  @seed :binary.copy(<<0x6B>>, 32)

  setup do
    previous = Application.get_env(:serviceradar_core, :edge_issuer_key_import_file)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_core, :edge_issuer_key_import_file, previous),
        else: Application.delete_env(:serviceradar_core, :edge_issuer_key_import_file)
    end)

    # An upgrade has no stored key yet; the sandbox transaction undoes this.
    Repo.query!("DELETE FROM platform.edge_issuer_key", [])
    :ok
  end

  test "the file seed is imported, keeps its public key, and earlier signatures verify", ctx do
    file_key = IssuerKey.from_seed(@seed)
    signed_before = IssuerKey.sign(capability(), file_key)
    import_from!(ctx.tmp_dir, Base.encode64(@seed) <> "\n", 0o600)

    assert {:ok, stored} = IssuerKey.ensure_stored()
    assert stored.public_key == file_key.public_key
    assert stored.key_id == file_key.key_id
    assert CapabilitySigning.verify(signed_before, :source, stored.public_key)

    # Stored once, the key no longer depends on the file.
    import_from!(ctx.tmp_dir, Base.encode64(:binary.copy(<<0x11>>, 32)), 0o600)
    assert {:ok, ^stored} = IssuerKey.ensure_stored()
  end

  test "a file that is not a private, well-formed seed stores no key", ctx do
    for {contents, mode} <- [
          {Base.encode64(@seed), 0o644},
          {"not base64!", 0o600},
          {<<0xFF, 0xFE>> <> @seed, 0o600}
        ] do
      import_from!(ctx.tmp_dir, contents, mode)

      assert {:error, :invalid_edge_issuer_key_file} = IssuerKey.ensure_stored()
      assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM platform.edge_issuer_key", [])
    end
  end

  defp import_from!(dir, contents, mode) do
    path = Path.join(dir, "edge-issuer-seed-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    File.chmod!(path, mode)
    Application.put_env(:serviceradar_core, :edge_issuer_key_import_file, path)
  end

  defp capability do
    %EdgeSignedCapabilityV1{
      not_before_unix_nano: 1_000,
      expires_at_unix_nano: 2_000,
      claims:
        {:source,
         %EdgeSourceClaimsV1{
           kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
           context_id: Ecto.UUID.bingenerate(),
           scope_id: Ecto.UUID.bingenerate(),
           scope_sha256: :crypto.hash(:sha256, "range"),
           collection_not_before_unix_nano: 1_000,
           collection_expires_unix_nano: 2_000
         }}
    }
  end
end
