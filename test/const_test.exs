defmodule ConstTest do
  use ExUnit.Case, async: true

  test "const with unsupported type" do
    assert_raise ArgumentError, "Unsupported type for const macro: tensor<*xf64>", fn ->
      defmodule GetIntIf do
        use Charms
        alias Charms.{Pointer, Term}

        defm get(env, i) :: Term.t() do
          zero = const 0 :: i32()
          one = const 1.0 :: f64()
          one = const 1.0 :: unranked_tensor(f64())
        end
      end
    end
  end
end
