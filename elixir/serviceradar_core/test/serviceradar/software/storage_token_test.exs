defmodule ServiceRadar.Software.StorageTokenTest do
  @moduledoc """
  Unit tests for HMAC-signed download URL generation and verification.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Software.StorageToken

  @moduletag :unit

  @test_secret "test-signing-secret-32bytes-long!"
  @test_url "https://radar.example.com"

  setup do
    prev = Application.get_env(:serviceradar_core, :software_storage)

    Application.put_env(:serviceradar_core, :software_storage,
      mode: :local,
      public_url: @test_url,
      signing_secret: @test_secret,
      download_ttl_seconds: 3600
    )

    on_exit(fn ->
      if prev do
        Application.put_env(:serviceradar_core, :software_storage, prev)
      else
        Application.delete_env(:serviceradar_core, :software_storage)
      end
    end)

    :ok
  end

  describe "download_url/2" do
    test "generates a valid signed URL" do
      image_id = "550e8400-e29b-41d4-a716-446655440000"
      object_key = "images/firmware-v1.2.bin"

      url = StorageToken.download_url(image_id, object_key)

      assert is_binary(url)
      assert String.starts_with?(url, @test_url)
      assert String.contains?(url, "/api/software-images/#{image_id}/download?token=")
    end

    test "returns nil when public_url is not configured" do
      Application.put_env(:serviceradar_core, :software_storage,
        mode: :local,
        signing_secret: @test_secret
      )

      assert StorageToken.download_url("id", "key") == nil
    end

    test "returns nil when signing_secret is not configured" do
      Application.put_env(:serviceradar_core, :software_storage,
        mode: :local,
        public_url: @test_url
      )

      assert StorageToken.download_url("id", "key") == nil
    end

    test "returns nil for empty object_key" do
      assert StorageToken.download_url("id", "") == nil
    end

    test "returns nil for nil arguments" do
      assert StorageToken.download_url(nil, nil) == nil
    end
  end

  describe "verify_token/1" do
    test "round-trip: generate then verify" do
      image_id = "550e8400-e29b-41d4-a716-446655440000"
      object_key = "images/firmware.bin"

      url = StorageToken.download_url(image_id, object_key)

      # Extract token from URL
      %URI{query: query} = URI.parse(url)
      %{"token" => token} = URI.decode_query(query)

      assert {:ok, payload} = StorageToken.verify_token(token)
      assert payload["id"] == image_id
      assert payload["key"] == object_key
      assert payload["act"] == "download"
      assert is_integer(payload["exp"])
    end

    test "rejects tampered token" do
      image_id = "550e8400-e29b-41d4-a716-446655440000"
      url = StorageToken.download_url(image_id, "images/test.bin")

      %URI{query: query} = URI.parse(url)
      %{"token" => token} = URI.decode_query(query)

      # Tamper with the payload portion
      [_payload_b64, sig] = String.split(token, ".", parts: 2)
      tampered_payload = Base.url_encode64("{\"id\":\"hacked\"}", padding: false)

      assert {:error, :invalid_signature} =
               StorageToken.verify_token(tampered_payload <> "." <> sig)
    end

    test "rejects expired token" do
      # Create a token that's already expired
      Application.put_env(:serviceradar_core, :software_storage,
        mode: :local,
        public_url: @test_url,
        signing_secret: @test_secret,
        download_ttl_seconds: -1
      )

      url = StorageToken.download_url("id", "key")
      %URI{query: query} = URI.parse(url)
      %{"token" => token} = URI.decode_query(query)

      assert {:error, :token_expired} = StorageToken.verify_token(token)
    end

    test "rejects malformed token" do
      assert {:error, :invalid_token_format} = StorageToken.verify_token("not-a-valid-token")
      assert {:error, :invalid_token_format} = StorageToken.verify_token("")
      assert {:error, :invalid_token_format} = StorageToken.verify_token(nil)
    end

    test "returns error when signing secret not configured" do
      Application.put_env(:serviceradar_core, :software_storage, mode: :local)

      assert {:error, :signing_secret_not_configured} =
               StorageToken.verify_token("payload.signature")
    end
  end
end
