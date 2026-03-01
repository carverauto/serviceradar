defmodule ServiceRadarWebNG.Edge.CryptoTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Edge.Crypto

  describe "generate_token/0" do
    test "generates a URL-safe base64 token" do
      token = Crypto.generate_token()
      assert is_binary(token)
      assert byte_size(token) > 20
      # URL-safe base64 should not contain + or /
      refute String.contains?(token, "+")
      refute String.contains?(token, "/")
    end

    test "generates unique tokens" do
      tokens = for _ <- 1..100, do: Crypto.generate_token()
      unique_tokens = Enum.uniq(tokens)
      assert length(unique_tokens) == 100
    end
  end

  describe "encrypt/1 and decrypt/1" do
    test "round-trips plaintext" do
      plaintext = "secret-join-token-12345"
      ciphertext = Crypto.encrypt(plaintext)
      decrypted = Crypto.decrypt(ciphertext)
      assert decrypted == plaintext
    end

    test "produces different ciphertext for same plaintext (unique IV)" do
      plaintext = "same-secret"
      ct1 = Crypto.encrypt(plaintext)
      ct2 = Crypto.encrypt(plaintext)
      assert ct1 != ct2
      # But both decrypt to same value
      assert Crypto.decrypt(ct1) == plaintext
      assert Crypto.decrypt(ct2) == plaintext
    end

    test "handles empty string" do
      plaintext = ""
      ciphertext = Crypto.encrypt(plaintext)
      assert Crypto.decrypt(ciphertext) == plaintext
    end

    test "handles unicode" do
      plaintext = "secret with unicode: \u{1F680} rocket"
      ciphertext = Crypto.encrypt(plaintext)
      assert Crypto.decrypt(ciphertext) == plaintext
    end

    test "decrypt raises on invalid ciphertext" do
      assert_raise RuntimeError, fn ->
        Crypto.decrypt("not-valid-base64!")
      end
    end

    test "decrypt raises on tampered ciphertext" do
      ciphertext = Crypto.encrypt("secret")
      # Tamper with the ciphertext
      tampered = ciphertext <> "x"

      assert_raise RuntimeError, fn ->
        Crypto.decrypt(tampered)
      end
    end
  end

  describe "decrypt_safe/1" do
    test "returns {:ok, plaintext} on success" do
      plaintext = "test-secret"
      ciphertext = Crypto.encrypt(plaintext)
      assert {:ok, ^plaintext} = Crypto.decrypt_safe(ciphertext)
    end

    test "returns {:error, :decrypt_failed} on failure" do
      assert {:error, :decrypt_failed} = Crypto.decrypt_safe("invalid")
    end
  end

  describe "hash_token/1" do
    test "produces consistent hash" do
      token = "my-download-token"
      hash1 = Crypto.hash_token(token)
      hash2 = Crypto.hash_token(token)
      assert hash1 == hash2
    end

    test "produces different hash for different tokens" do
      hash1 = Crypto.hash_token("token-1")
      hash2 = Crypto.hash_token("token-2")
      assert hash1 != hash2
    end

    test "produces hex-encoded 64-character hash (SHA256)" do
      hash = Crypto.hash_token("any-token")
      assert String.length(hash) == 64
      assert String.match?(hash, ~r/^[0-9a-f]+$/)
    end
  end

  describe "verify_token/2" do
    test "returns true for matching token" do
      token = "my-secret-token"
      hash = Crypto.hash_token(token)
      assert Crypto.verify_token(token, hash) == true
    end

    test "returns false for non-matching token" do
      hash = Crypto.hash_token("correct-token")
      assert Crypto.verify_token("wrong-token", hash) == false
    end

    test "returns false for nil inputs" do
      assert Crypto.verify_token(nil, "hash") == false
      assert Crypto.verify_token("token", nil) == false
    end
  end
end
