defmodule ServiceRadar.Edge.RemoteAccessSSHCACommandSignerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RemoteAccessSSHCACommandSigner

  test "signs a certificate by invoking an external command with JSON stdin" do
    dir = tmp_dir()
    capture_path = Path.join(dir, "request.json")

    command =
      executable_script(
        dir,
        "signer-success",
        """
        #!/bin/sh
        cat > "$CAPTURE_PATH"
        printf '%s\\n' '{"certificate":"ssh-ed25519-cert-v01@openssh.com AAAATEST","expires_at":"2026-05-09T13:00:00Z","fingerprint":"SHA256:test","serial":42}'
        """
      )

    request = %{
      public_key: "ssh-ed25519 AAAATEST user@workstation",
      key_id: "sr:remote-access:session-1:user-1:agent-1:ssh:device-1",
      principals: ["ubuntu"],
      ttl_seconds: 900
    }

    assert {:ok, signed} =
             RemoteAccessSSHCACommandSigner.sign_user_certificate(request,
               command: command,
               env: [{"CAPTURE_PATH", capture_path}],
               ca_key_id: "ca-main"
             )

    assert signed == %{
             certificate: "ssh-ed25519-cert-v01@openssh.com AAAATEST",
             expires_at: ~U[2026-05-09 13:00:00Z],
             fingerprint: "SHA256:test",
             serial: 42,
             ca_key_id: "ca-main"
           }

    assert Jason.decode!(File.read!(capture_path)) == %{
             "public_key" => "ssh-ed25519 AAAATEST user@workstation",
             "key_id" => "sr:remote-access:session-1:user-1:agent-1:ssh:device-1",
             "principals" => ["ubuntu"],
             "ttl_seconds" => 900
           }
  end

  test "returns command failures without exposing request material" do
    dir = tmp_dir()

    command =
      executable_script(
        dir,
        "signer-failed",
        """
        #!/bin/sh
        cat >/dev/null
        echo 'signer failed cleanly' >&2
        exit 17
        """
      )

    assert {:error, {:ssh_certificate_signer_failed, 17, "signer failed cleanly"}} =
             RemoteAccessSSHCACommandSigner.sign_user_certificate(request_fixture(),
               command: command
             )
  end

  test "rejects invalid signer JSON responses" do
    dir = tmp_dir()

    command =
      executable_script(
        dir,
        "signer-invalid-json",
        """
        #!/bin/sh
        cat >/dev/null
        printf 'not json'
        """
      )

    assert {:error, :ssh_certificate_signer_invalid_json} =
             RemoteAccessSSHCACommandSigner.sign_user_certificate(request_fixture(),
               command: command
             )
  end

  test "rejects missing certificates in signer responses" do
    dir = tmp_dir()

    command =
      executable_script(
        dir,
        "signer-missing-certificate",
        """
        #!/bin/sh
        cat >/dev/null
        printf '%s\\n' '{"expires_at":"2026-05-09T13:00:00Z"}'
        """
      )

    assert {:error, :ssh_certificate_signer_invalid_response} =
             RemoteAccessSSHCACommandSigner.sign_user_certificate(request_fixture(),
               command: command
             )
  end

  defp request_fixture do
    %{
      public_key: "ssh-ed25519 AAAATEST user@workstation",
      key_id: "sr:remote-access:session-1:user-1:agent-1:ssh:device-1",
      principals: ["ubuntu"],
      ttl_seconds: 900
    }
  end

  defp tmp_dir do
    dir =
      Path.join([
        System.tmp_dir!(),
        "serviceradar-sshca-command-signer-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    dir
  end

  defp executable_script(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    File.chmod!(path, 0o700)
    path
  end
end
