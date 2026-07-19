defmodule ServiceRadar.Plugins.AddonUpdatePolicyBackfillWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.AddonUpdatePolicyBackfillWorker

  describe "successful_state_names/0" do
    test "returns Oban's successful unique states as strings" do
      names = AddonUpdatePolicyBackfillWorker.successful_state_names()

      assert names == Enum.map(Oban.Job.unique_states(:successful), &to_string/1)
      assert Enum.all?(names, &is_binary/1)
      assert "completed" in names
    end
  end
end
