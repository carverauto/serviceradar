defmodule ServiceRadarWebNG.ShellTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Shell

  @moduletag :db_free

  describe "literal/1" do
    test "single-quotes a POSIX value and escapes embedded quotes" do
      assert Shell.literal("a'b $(x)") == ~S|'a'"'"'b $(x)'|
    end
  end

  describe "powershell_literal/1" do
    test "single-quotes a PowerShell value and doubles embedded quotes" do
      assert Shell.powershell_literal("a'b $env:PATH") == "'a''b $env:PATH'"
    end
  end
end
