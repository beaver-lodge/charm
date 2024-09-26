defmodule AddTwoIntVec do
  use Charms
  alias Charms.{SIMD, Term, Pointer}

  defm load_list(env, l :: Term.t()) :: SIMD.t(i32(), 8) do
    i_ptr = Pointer.allocate(i32())
    Pointer.store(const(0 :: i32()), i_ptr)
    init = SIMD.new(i32(), 8).(0, 0, 0, 0, 0, 0, 0, 0)

    Enum.reduce(l, init, fn x, acc ->
      v_ptr = Pointer.allocate(i32())
      enif_get_int(env, x, v_ptr)
      i = Pointer.load(i32(), i_ptr)
      Pointer.store(i + 1, i_ptr)

      Pointer.load(i32(), v_ptr)
      |> vector.insertelement(acc, i)
    end)
    |> func.return()
  end

  defm add(env, a, b, error) :: Term.t() do
    v1 = call load_list(env, a) :: SIMD.t(i32(), 8)
    v2 = call load_list(env, b) :: SIMD.t(i32(), 8)
    v = arith.addi(v1, v2)
    start = arith.constant(value: Attribute.integer(i32(), 0))

    ret =
      enif_make_list8(
        env,
        enif_make_int(env, vector.extractelement(v, start)),
        enif_make_int(env, vector.extractelement(v, start + 1)),
        enif_make_int(env, vector.extractelement(v, start + 2)),
        enif_make_int(env, vector.extractelement(v, start + 3)),
        enif_make_int(env, vector.extractelement(v, start + 4)),
        enif_make_int(env, vector.extractelement(v, start + 5)),
        enif_make_int(env, vector.extractelement(v, start + 6)),
        enif_make_int(env, vector.extractelement(v, start + 7))
      )

    func.return(ret)
  end

  defm dummy_load_no_make(env, a, b, error) :: Term.t() do
    v1 = call load_list(env, a) :: SIMD.t(i32(), 8)
    v2 = call load_list(env, b) :: SIMD.t(i32(), 8)
    func.return(a)
  end

  defm dummy_return(env, a, b, error) :: Term.t() do
    func.return(a)
  end
end
