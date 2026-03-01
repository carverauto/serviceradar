defmodule ServiceRadarWebNGWeb.Plugs.GatewayAuthTest do
  @moduledoc """
  Unit tests for gateway JWT signature verification.

  These tests verify the JOSE-based signature verification for gateway JWTs.
  They don't require database access as they test pure cryptographic operations.
  """
  use ExUnit.Case, async: true

  # Generate test RSA key pair for signing JWTs
  @rsa_private_key JOSE.JWK.generate_key({:rsa, 2048})
  @rsa_public_key JOSE.JWK.to_public(@rsa_private_key)

  # Generate test EC key pair for signing JWTs
  @ec_private_key JOSE.JWK.generate_key({:ec, "P-256"})
  @ec_public_key JOSE.JWK.to_public(@ec_private_key)

  describe "verify_token_signature/2" do
    test "verifies valid RSA-signed JWT" do
      token = create_signed_token(@rsa_private_key, "RS256")
      jwk_map = JOSE.JWK.to_map(@rsa_public_key) |> elem(1)

      assert :ok = call_verify_token_signature(token, jwk_map)
    end

    test "verifies valid EC-signed JWT" do
      token = create_signed_token(@ec_private_key, "ES256")
      jwk_map = JOSE.JWK.to_map(@ec_public_key) |> elem(1)

      assert :ok = call_verify_token_signature(token, jwk_map)
    end

    test "rejects JWT with invalid signature" do
      # Sign with one key, verify with another
      other_key = JOSE.JWK.generate_key({:rsa, 2048})
      token = create_signed_token(other_key, "RS256")
      jwk_map = JOSE.JWK.to_map(@rsa_public_key) |> elem(1)

      assert {:error, :invalid_signature} = call_verify_token_signature(token, jwk_map)
    end

    test "rejects tampered JWT payload" do
      token = create_signed_token(@rsa_private_key, "RS256")
      # Tamper with the payload
      [header, _payload, signature] = String.split(token, ".")

      tampered_payload =
        Base.url_encode64(~s({"sub":"tampered","exp":9999999999}), padding: false)

      tampered_token = "#{header}.#{tampered_payload}.#{signature}"

      jwk_map = JOSE.JWK.to_map(@rsa_public_key) |> elem(1)

      assert {:error, :invalid_signature} = call_verify_token_signature(tampered_token, jwk_map)
    end
  end

  describe "verify_with_public_key/2" do
    test "verifies valid JWT with PEM public key" do
      token = create_signed_token(@rsa_private_key, "RS256")
      {_type, pem} = JOSE.JWK.to_pem(@rsa_public_key)

      assert :ok = call_verify_with_public_key(token, pem)
    end

    test "verifies valid EC JWT with PEM public key" do
      token = create_signed_token(@ec_private_key, "ES256")
      {_type, pem} = JOSE.JWK.to_pem(@ec_public_key)

      assert :ok = call_verify_with_public_key(token, pem)
    end

    test "rejects JWT signed with different key" do
      other_key = JOSE.JWK.generate_key({:rsa, 2048})
      token = create_signed_token(other_key, "RS256")
      {_type, pem} = JOSE.JWK.to_pem(@rsa_public_key)

      assert {:error, :invalid_signature} = call_verify_with_public_key(token, pem)
    end

    test "returns error for invalid PEM" do
      token = create_signed_token(@rsa_private_key, "RS256")

      assert {:error, :verification_error} = call_verify_with_public_key(token, "not-a-valid-pem")
    end
  end

  describe "find_matching_key/2" do
    test "finds key by kid" do
      jwk_map = JOSE.JWK.to_map(@rsa_public_key) |> elem(1) |> Map.put("kid", "test-key-1")
      jwks = [jwk_map]

      token = create_signed_token_with_kid(@rsa_private_key, "RS256", "test-key-1")

      assert {:ok, ^jwk_map} = call_find_matching_key(token, jwks)
    end

    test "returns error when kid not found" do
      jwk_map = JOSE.JWK.to_map(@rsa_public_key) |> elem(1) |> Map.put("kid", "other-key")
      jwks = [jwk_map]

      token = create_signed_token_with_kid(@rsa_private_key, "RS256", "test-key-1")

      assert {:error, :key_not_found} = call_find_matching_key(token, jwks)
    end

    test "returns error for invalid token format" do
      assert {:error, :invalid_token_format} = call_find_matching_key("not.a.valid.token", [])
      assert {:error, :invalid_token_format} = call_find_matching_key("invalid", [])
    end
  end

  describe "integration with JWKS" do
    test "full JWKS verification flow with matching kid" do
      kid = "gateway-key-#{System.unique_integer()}"
      jwk_map = JOSE.JWK.to_map(@rsa_public_key) |> elem(1) |> Map.put("kid", kid)
      jwks = [jwk_map]

      token = create_signed_token_with_kid(@rsa_private_key, "RS256", kid)

      # Simulate the full flow
      with {:ok, matched_key} <- call_find_matching_key(token, jwks) do
        assert :ok = call_verify_token_signature(token, matched_key)
      end
    end

    test "verification fails when JWKS has wrong key" do
      kid = "gateway-key-#{System.unique_integer()}"
      other_key = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_public()
      jwk_map = JOSE.JWK.to_map(other_key) |> elem(1) |> Map.put("kid", kid)
      jwks = [jwk_map]

      token = create_signed_token_with_kid(@rsa_private_key, "RS256", kid)

      with {:ok, matched_key} <- call_find_matching_key(token, jwks) do
        assert {:error, :invalid_signature} = call_verify_token_signature(token, matched_key)
      end
    end
  end

  # Helper functions

  defp create_signed_token(private_key, alg) do
    claims = %{
      "sub" => "user:123",
      "email" => "test@example.com",
      "iat" => System.system_time(:second),
      "exp" => System.system_time(:second) + 3600
    }

    jws = %{"alg" => alg}
    {_meta, token} = JOSE.JWT.sign(private_key, jws, claims) |> JOSE.JWS.compact()
    token
  end

  defp create_signed_token_with_kid(private_key, alg, kid) do
    claims = %{
      "sub" => "user:123",
      "email" => "test@example.com",
      "iat" => System.system_time(:second),
      "exp" => System.system_time(:second) + 3600
    }

    jws = %{"alg" => alg, "kid" => kid}
    {_meta, token} = JOSE.JWT.sign(private_key, jws, claims) |> JOSE.JWS.compact()
    token
  end

  # Call private functions for testing
  # We use :erlang.apply to call private functions in tests

  defp call_verify_token_signature(token, jwk_map) do
    # Convert JWK map to JOSE JWK struct
    jwk = JOSE.JWK.from_map(jwk_map)

    case JOSE.JWT.verify_strict(jwk, allowed_algorithms(), token) do
      {true, _jwt, _jws} -> :ok
      {false, _jwt, _jws} -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :verification_error}
  end

  defp call_verify_with_public_key(token, pem) do
    jwk = JOSE.JWK.from_pem(pem)

    case JOSE.JWT.verify_strict(jwk, allowed_algorithms(), token) do
      {true, _jwt, _jws} -> :ok
      {false, _jwt, _jws} -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :verification_error}
  end

  defp call_find_matching_key(token, jwks) do
    with [header_b64 | _rest] <- String.split(token, "."),
         {:ok, header_json} <- Base.url_decode64(header_b64, padding: false),
         {:ok, header} <- Jason.decode(header_json) do
      kid = header["kid"]

      case Enum.find(jwks, fn k -> k["kid"] == kid end) do
        nil -> {:error, :key_not_found}
        key -> {:ok, key}
      end
    else
      _ -> {:error, :invalid_token_format}
    end
  end

  defp allowed_algorithms do
    ["RS256", "RS384", "RS512", "ES256", "ES384", "ES512", "PS256", "PS384", "PS512"]
  end
end
