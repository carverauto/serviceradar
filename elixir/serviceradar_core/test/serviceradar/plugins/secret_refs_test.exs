defmodule ServiceRadar.Plugins.SecretRefsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.SecretRefs

  @schema %{
    "type" => "object",
    "properties" => %{
      "host" => %{"type" => "string"},
      "password_secret_ref" => %{"type" => "string", "secretRef" => true},
      "stream_auth_mode" => %{"type" => "string"}
    }
  }

  setup do
    original = Application.get_env(:serviceradar_core, :crypto_secret)
    Application.put_env(:serviceradar_core, :crypto_secret, String.duplicate("a", 32))

    on_exit(fn ->
      if original do
        Application.put_env(:serviceradar_core, :crypto_secret, original)
      else
        Application.delete_env(:serviceradar_core, :crypto_secret)
      end
    end)

    :ok
  end

  test "stores secret fields as refs plus encrypted material and redacts public params" do
    stored =
      SecretRefs.prepare_params_for_storage(@schema, %{
        "host" => "camera.local",
        "password_secret_ref" => "super-secret"
      })

    assert stored["host"] == "camera.local"
    assert String.starts_with?(stored["password_secret_ref"], "secretref:")
    assert is_map(stored["_secret_material"])
    refute stored["_secret_material"][stored["password_secret_ref"]] == "super-secret"

    assert %{
             "host" => "camera.local",
             "password_secret_ref" => ref
           } = SecretRefs.public_params(stored)

    assert String.starts_with?(ref, "secretref:")
  end

  test "preserves existing secret refs when update leaves field blank" do
    existing =
      SecretRefs.prepare_params_for_storage(@schema, %{
        "password_secret_ref" => "super-secret"
      })

    updated =
      SecretRefs.prepare_params_for_storage(
        @schema,
        %{"host" => "camera.local", "password_secret_ref" => ""},
        existing
      )

    assert updated["password_secret_ref"] == existing["password_secret_ref"]
    assert updated["_secret_material"][existing["password_secret_ref"]] ==
             existing["_secret_material"][existing["password_secret_ref"]]
  end

  test "resolves runtime params by decrypting secret refs" do
    stored =
      SecretRefs.prepare_params_for_storage(@schema, %{
        "host" => "camera.local",
        "password_secret_ref" => "super-secret"
      })

    assert {:ok, runtime} = SecretRefs.resolve_runtime_params(@schema, stored)
    assert runtime["host"] == "camera.local"
    assert runtime["password"] == "super-secret"
    assert runtime["password_secret_ref"] == stored["password_secret_ref"]
    refute Map.has_key?(runtime, "_secret_material")
  end

  test "validates linked secret material for secret refs" do
    assert {:error, [message]} =
             SecretRefs.validate_secret_linkage(@schema, %{
               "password_secret_ref" => "secretref:password:missing"
             })

    assert message =~ "missing linked secret material"
  end
end
