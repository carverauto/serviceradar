defmodule CertificateCodecBridge do
  @moduledoc false
  alias ServiceRadar.NATS.CertificateAuthorizationToken

  def main(_) do
    Enum.each(IO.stream(:stdio, :line), fn line ->
      input = Jason.decode!(line)
      result = respond(input)
      IO.puts(Jason.encode!(result))
    end)
  end

  defp respond(input) do
    case CertificateAuthorizationToken.decode_request(input["request"], input["issuer"], input["now"] || System.system_time(:second)) do
      {:ok, request} ->
        {:ok, signer} = NKEYS.Keypair.from_seed(input["seed"])

        decision =
          if input["allow"] do
            {:allow, %{publish: [">"], subscribe: [">"], expires_at: System.system_time(:second) + 30}}
          else
            {:deny, "certificate not authorized"}
          end

        %{
          "fingerprint" => request.fingerprint,
          "token" => CertificateAuthorizationToken.encode_response(request, decision, signer, "APP")
        }

      {:error, reason} ->
        %{"error" => Atom.to_string(reason)}
    end
  end
end
