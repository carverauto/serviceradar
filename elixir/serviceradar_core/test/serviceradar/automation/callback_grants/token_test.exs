defmodule ServiceRadar.Automation.CallbackGrants.TokenTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.CallbackGrants.HMACKeyedVerifier
  alias ServiceRadar.Automation.CallbackGrants.Token

  @config [
    active_key_id: "primary-2026",
    keys: %{
      "primary-2026" => String.duplicate("p", 32),
      "retiring-2025" => String.duplicate("r", 32)
    }
  ]

  test "issues 256-bit URL-safe opaque tokens and stores only a keyed digest" do
    assert {:ok, issued} =
             Token.issue(HMACKeyedVerifier, @config,
               random_bytes: fn 32 -> :binary.copy(<<255>>, 32) end
             )

    assert byte_size(issued.bearer) == 43
    assert issued.bearer =~ ~r/\A[A-Za-z0-9_-]+\z/
    assert issued.verifier_key_id == "primary-2026"
    assert byte_size(issued.verifier_digest) == 32

    grant = Map.delete(issued, :bearer)
    assert :ok = Token.verify(issued.bearer, grant, HMACKeyedVerifier, @config)

    assert {:error, :invalid_callback_grant} =
             Token.verify("wrong", grant, HMACKeyedVerifier, @config)
  end

  test "rotated verifier keys work only while their keyed material is retained" do
    bearer = "opaque-callback-bearer"

    assert {:ok, digest} =
             HMACKeyedVerifier.digest(
               "retiring-2025",
               "serviceradar-callback-bearer-v1\0" <> bearer,
               @config
             )

    grant = %{verifier_key_id: "retiring-2025", verifier_digest: digest}
    assert :ok = Token.verify(bearer, grant, HMACKeyedVerifier, @config)

    pruned = Keyword.put(@config, :keys, %{"primary-2026" => String.duplicate("p", 32)})

    assert {:error, :invalid_callback_grant} =
             Token.verify(bearer, grant, HMACKeyedVerifier, pruned)
  end

  test "server-minted idempotency keys bind to a private domain-separated verifier" do
    assert {:ok, issued} =
             Token.issue_idempotency_key(HMACKeyedVerifier, @config,
               random_bytes: fn 32 -> :binary.copy(<<7>>, 32) end
             )

    assert issued.idempotency_key =~ ~r/\Asrci_v1_[A-Za-z0-9_-]+\z/
    assert issued.verifier_key_id == "primary-2026"
    assert byte_size(issued.verifier_digest) == 32

    grant = %{
      idempotency_verifier_key_id: issued.verifier_key_id,
      idempotency_verifier_digest: issued.verifier_digest
    }

    assert :ok =
             Token.verify_idempotency_key(
               issued.idempotency_key,
               grant,
               HMACKeyedVerifier,
               @config
             )

    assert {:error, :invalid_idempotency_key} =
             Token.verify_idempotency_key(
               "srci_v1_" <> String.duplicate("x", 43),
               grant,
               HMACKeyedVerifier,
               @config
             )
  end

  test "weak verifier keys and short entropy sources fail closed" do
    weak = [active_key_id: "weak", keys: %{"weak" => "short"}]

    assert {:error, :verifier_key_unavailable} =
             Token.issue(HMACKeyedVerifier, weak,
               random_bytes: fn 32 -> :binary.copy(<<1>>, 32) end
             )

    assert {:error, :insufficient_callback_token_entropy} =
             Token.issue(HMACKeyedVerifier, @config, random_bytes: fn 32 -> <<1, 2>> end)
  end
end
