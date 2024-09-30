defmodule SupervisorTest do
  use ExUnit.Case

  test "init module with supervisor" do
    {:ok, _} =
      DynamicSupervisor.start_child(Charms.TestDynamicSupervisor, Charms.child_spec(ChildMod))

    assert ChildMod.term_roundtrip(100) == 100
  end

  test "init merged modules with supervisor" do
    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Charms.TestDynamicSupervisor,
        Charms.child_spec([ChildMod, ChildMod2], name: ChildModMerged)
      )

    jit = Charms.JIT.get(ChildModMerged)
    assert Charms.JIT.invoke(jit, &ChildMod2.term_roundtrip/1, [100]) == 100
  end
end
