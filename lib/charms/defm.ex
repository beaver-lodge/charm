defmodule Charms.Defm do
  @moduledoc """
  Charms.Defm provides a macro for defining functions that can be JIT compiled
  """
  use Beaver
  alias MLIR.Dialect.Func
  require Func

  @doc """
  create an MLIR operation
  """
  defmacro op(_), do: :implemented_in_expander

  @doc """
  create an MLIR operation and return the result value(s)
  """
  defmacro value(_expr), do: :implemented_in_expander

  @doc """
  call a local function with return
  """
  defmacro call({:"::", _, [_call, _types]}), do: :implemented_in_expander

  @doc """
  call a function defined in another `Charms` module with return
  """
  defmacro call(_mod, {:"::", _, [_call, _types]}), do: :implemented_in_expander

  @doc """
  for loop
  """
  defmacro for_loop(_expr, do: _body), do: :implemented_in_expander

  @doc """
  while loop
  """
  defmacro while_loop(_expr, do: _body), do: :implemented_in_expander

  @doc """
  `cond` expression requires identical types for both branches
  """
  defmacro cond_br(_condition, _clauses), do: :implemented_in_expander

  @doc """
  `if` expression requires identical types for both branches
  """
  defmacro struct_if(_condition, _clauses), do: :implemented_in_expander

  @doc """
  define a function that can be JIT compiled
  """
  defmacro defm(call, body \\ []) do
    {call, ret_types} = decompose_call_and_returns(call)

    call = normalize_call(call)
    {name, args} = Macro.decompose_call(call)
    env = __CALLER__
    [_enif_env | invoke_args] = args

    invoke_args =
      for {:"::", _, [a, _t]} <- invoke_args do
        a
      end

    quote do
      @defm unquote(Macro.escape({env, {call, ret_types, body}}))
      def unquote(name)(unquote_splicing(invoke_args)) do
        f =
          &Charms.JIT.invoke(&1, {unquote(env.module), unquote(name), unquote(invoke_args)})

        if jit = Charms.JIT.get(__MODULE__) do
          f.(jit)
        else
          f
        end
      end
    end
  end

  @doc false
  def decompose_call_and_returns(call) do
    case call do
      {:"::", _, [call, ret_type]} -> {call, [ret_type]}
      call -> {call, []}
    end
  end

  @doc false
  defp normalize_call(call) do
    {name, args} = Macro.decompose_call(call)

    args =
      for i <- Enum.with_index(args) do
        case i do
          # env
          {a = {:env, _, nil}, 0} ->
            quote do
              unquote(a) :: Charms.Env.t()
            end

          # term
          {a = {name, _, context}, version}
          when is_atom(name) and is_atom(context) and is_integer(version) ->
            quote do
              unquote(a) :: Charms.Term.t()
            end

          # typed
          {at = {:"::", _, [_a, _t]}, _} ->
            at
        end
      end

    quote do
      unquote(name)(unquote_splicing(args))
    end
  end

  @doc false
  def compile_definitions(definitions) do
    import MLIR.Transforms
    ctx = MLIR.Context.create()
    available_ops = MapSet.new(MLIR.Dialect.Registry.ops(:all, ctx: ctx))

    m =
      mlir ctx: ctx do
        module do
          mlir = %{
            ctx: ctx,
            blk: Beaver.Env.block(),
            available_ops: available_ops,
            vars: Map.new(),
            region: nil
          }

          for {env, d} <- definitions do
            {call, ret_types, body} = d

            ast =
              quote do
                def(unquote(call) :: unquote(ret_types), unquote(body))
              end

            Charms.Defm.Expander.expand_with_mlir(
              ast,
              mlir,
              env
            )
          end
        end
      end
      |> MLIR.Pass.Composer.nested(
        "func.func",
        Charms.Defm.Pass.CreateAbsentFunc
      )
      |> canonicalize
      |> MLIR.Pass.Composer.run!(print: System.get_env("DEFM_PRINT_IR") == "1")
      |> MLIR.to_string(bytecode: true)

    MLIR.Context.destroy(ctx)
    m
  end

  @doc false
  def mangling(mod, func) do
    Module.concat(mod, func)
  end
end
