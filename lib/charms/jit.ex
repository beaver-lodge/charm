defmodule Charms.JIT do
  alias Beaver.MLIR.Dialect.Func
  import Beaver.MLIR.CAPI
  alias Beaver.MLIR

  defstruct ctx: nil, engine: nil, owner: true

  defp jit_of_mod(m) do
    import Beaver.MLIR.{Conversion, Transforms}

    m
    |> MLIR.Operation.verify!(debug: true)
    |> MLIR.Pass.Composer.nested("func.func", "llvm-request-c-wrappers")
    |> MLIR.Pass.Composer.nested("func.func", loop_invariant_code_motion())
    |> convert_scf_to_cf
    |> convert_arith_to_llvm()
    |> convert_index_to_llvm()
    |> convert_func_to_llvm()
    |> MLIR.Pass.Composer.append("convert-vector-to-llvm{reassociate-fp-reductions}")
    |> MLIR.Pass.Composer.append("finalize-memref-to-llvm")
    |> reconcile_unrealized_casts
    |> Charms.Debug.print_ir_pass()
    |> MLIR.Pass.Composer.run!(print: Charms.Debug.step_print?())
    |> MLIR.ExecutionEngine.create!(opt_level: 3, object_dump: true)
    |> tap(&beaver_raw_jit_register_enif(&1.ref))
  end

  defp clone_func_impl(to, from) do
    ops = MLIR.Module.body(from) |> Beaver.Walker.operations()
    s_table = to |> MLIR.Operation.from_module() |> mlirSymbolTableCreate()

    for op <- ops, MLIR.Operation.name(op) == "func.func" do
      sym = mlirOperationGetAttributeByName(op, mlirSymbolTableGetSymbolAttributeName())
      found = mlirSymbolTableLookup(s_table, mlirStringAttrGetValue(sym))
      body = MLIR.Module.body(to)

      if MLIR.is_null(found) do
        mlirBlockAppendOwnedOperation(body, mlirOperationClone(op))
      else
        unless Func.is_external(op) do
          mlirOperationDestroy(found)
          mlirBlockAppendOwnedOperation(body, mlirOperationClone(op))
        end
      end
    end

    mlirSymbolTableDestroy(s_table)
  end

  defp merge_modules(modules, opts \\ []) do
    destroy = opts[:destroy] || true
    [head | tail] = modules

    for module <- tail do
      if MLIR.is_null(module) do
        raise "can't merge a null module"
      end

      clone_func_impl(head, module)

      if destroy do
        MLIR.Module.destroy(module)
      end
    end

    head
  end

  def init(module, opts \\ [])

  def init({:module, module, binary, _}, opts) when is_atom(module) and is_binary(binary) do
    init(module, opts)
  end

  def init(module, opts) when is_atom(module) do
    name = opts[:name] || module
    opts = Keyword.put_new(opts, :name, name)
    init([module], opts)
  end

  def init(modules, opts) do
    ctx = MLIR.Context.create()
    Beaver.Diagnostic.attach(ctx)
    modules = modules |> List.wrap()

    jit =
      modules
      |> Enum.map(fn
        m when is_atom(m) -> m.__ir__() |> then(&MLIR.Module.create(ctx, &1))
        s when is_binary(s) -> s |> then(&MLIR.Module.create(ctx, &1))
        %MLIR.Module{} = m -> m
      end)
      |> merge_modules()
      |> jit_of_mod
      |> then(&%__MODULE__{ctx: ctx, engine: &1})

    case {opts[:name], modules} do
      {name, [_]} when not is_nil(name) ->
        Agent.start_link(fn -> jit end, name: name)

      {nil, modules} ->
        for {module, index} <- Enum.with_index(modules) do
          Agent.start_link(fn -> %__MODULE__{jit | owner: index == 0} end, name: module)
        end

      {name, modules} when not is_nil(name) and is_list(modules) ->
        Agent.start_link(fn -> jit end, name: name)
    end
  end

  @doc """
  Returns the JIT engine for the given module.
  """
  def engine(module) do
    if pid = Process.whereis(module) do
      Agent.get(pid, & &1).engine
    end
  end

  def invoke(%MLIR.ExecutionEngine{ref: ref}, {mod, func, args}) do
    beaver_raw_jit_invoke_with_terms(ref, to_string(Charms.Defm.mangling(mod, func)), args)
  end

  def invoke(%MLIR.ExecutionEngine{} = engine, f, args)
      when is_function(f, length(args)) do
    apply(f, args).(engine)
  end

  def destroy(module) do
    with %__MODULE__{ctx: ctx, engine: engine, owner: true} <- Agent.get(module, & &1) do
      MLIR.ExecutionEngine.destroy(engine)
      MLIR.Context.destroy(ctx)
    end

    Agent.stop(module)
  end
end
