defmodule ServiceRadar.Automation.CallbackGrants.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.CallbackGrants.RuntimeConfig

  test "decodes an exact bounded rotating keyring" do
    key = :crypto.strong_rand_bytes(32)

    assert {:ok, config} =
             RuntimeConfig.verifier_config(%{
               "active_key_id" => "callback-v2",
               "keys" => %{
                 "callback-v1" => Base.encode64(:crypto.strong_rand_bytes(32)),
                 "callback-v2" => Base.encode64(key)
               }
             })

    assert config[:active_key_id] == "callback-v2"
    assert config[:keys]["callback-v2"] == key
  end

  test "rejects inline ambiguity, short keys, and absent active keys" do
    valid_key = Base.encode64(:crypto.strong_rand_bytes(32))

    assert {:error, :invalid_verifier_config} =
             RuntimeConfig.verifier_config(%{
               "active_key_id" => "callback-v1",
               "keys" => %{"callback-v1" => valid_key},
               "unexpected" => true
             })

    assert {:error, :invalid_verifier_config} =
             RuntimeConfig.verifier_config(%{
               "active_key_id" => "callback-v1",
               "keys" => %{"callback-v1" => Base.encode64("short")}
             })

    assert {:error, :invalid_verifier_config} =
             RuntimeConfig.verifier_config(%{
               "active_key_id" => "callback-v2",
               "keys" => %{"callback-v1" => valid_key}
             })
  end

  @tag :tmp_dir
  test "loads only a bounded non-world-readable keyring file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "callback-keyring.json")

    document = %{
      "active_key_id" => "callback-v1",
      "keys" => %{"callback-v1" => Base.encode64(:crypto.strong_rand_bytes(32))}
    }

    File.write!(path, Jason.encode!(document))
    File.chmod!(path, 0o600)
    assert RuntimeConfig.load_verifier_file!(path)[:active_key_id] == "callback-v1"

    File.chmod!(path, 0o604)

    assert_raise RuntimeError, "invalid automation callback HMAC keyring file", fn ->
      RuntimeConfig.load_verifier_file!(path)
    end
  end
end
