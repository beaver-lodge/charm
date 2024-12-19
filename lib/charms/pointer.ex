defmodule Charms.Pointer do
  @moduledoc """
  Intrinsic module to work with pointers.

  Charms.Pointer should be the "smart pointer" not just comes with lifetime management, but also SIMD and Tensor support.
  """
  use Beaver
  use Charms.Intrinsic
  alias Charms.Intrinsic.Opts
  alias Beaver.MLIR.{Type}
  alias Beaver.MLIR.Dialect.{MemRef, Index, Arith}

  @doc """
  Allocates a single element of the given `elem_type`, returning a pointer to it.
  """
  defintrinsic allocate(elem_type) do
    quote bind_quoted: [elem_type: elem_type] do
      Charms.Pointer.allocate(elem_type, 1)
    end
  end

  @doc """
  Allocates an array of `size` elements of the given `elem_type`, returning a pointer to it.
  """
  defintrinsic allocate(elem_type, size) do
    %Opts{ctx: ctx, blk: blk, loc: loc} = __IR__

    mlir ctx: ctx, blk: blk do
      zero = Index.constant(value: Attribute.index(0)) >>> Type.index()

      case size do
        i when is_integer(i) ->
          MemRef.alloca(
            loc: loc,
            operand_segment_sizes: Beaver.MLIR.ODS.operand_segment_sizes([0, 0])
          ) >>> Type.memref([i], elem_type)

        %MLIR.Value{} ->
          size =
            if Type.index?(MLIR.Value.type(size)) do
              size
            else
              Index.casts(size, loc: loc) >>> Type.index()
            end

          MemRef.alloca(size,
            loc: loc,
            operand_segment_sizes: Beaver.MLIR.ODS.operand_segment_sizes([1, 0])
          ) >>> Type.memref([:dynamic], elem_type)
      end
      |> offset_ptr(elem_type, zero, ctx, blk, loc)
    end
  end

  @doc """
  Loads a value of `type` from the given pointer `ptr`.
  """
  defintrinsic load(type, ptr) do
    %Opts{ctx: ctx, blk: blk, loc: loc} = __IR__

    if MLIR.equal?(MLIR.Value.type(ptr), ~t{!llvm.ptr}) do
      quote bind_quoted: [type: type, ptr: ptr] do
        value llvm.load(ptr) :: type
      end
    else
      mlir ctx: ctx, blk: blk do
        zero = Index.constant(value: Attribute.index(0), loc: loc) >>> Type.index()
        MemRef.load(ptr, zero, loc: loc) >>> type
      end
    end
  end

  @doc false
  def memref_ptr?(%MLIR.Type{} = t) do
    MLIR.CAPI.mlirTypeIsAMemRef(t) |> Beaver.Native.to_term()
  end

  def memref_ptr?(%MLIR.Value{} = ptr) do
    MLIR.Value.type(ptr) |> memref_ptr?()
  end

  defintrinsic load(%MLIR.Value{} = ptr) do
    t = MLIR.Value.type(ptr)

    if memref_ptr?(t) do
      quote do
        Charms.Pointer.load(unquote(MLIR.CAPI.mlirShapedTypeGetElementType(t)), unquote(ptr))
      end
    else
      raise ArgumentError, "Pointer is not typed, use load/2 to specify the pointer type"
    end
  end

  @doc """
  Stores a value `val` at the given pointer `ptr`.
  """
  defintrinsic store(val, ptr) do
    %Opts{ctx: ctx, blk: blk, loc: loc} = __IR__

    mlir ctx: ctx, blk: blk do
      zero = Index.constant(value: Attribute.index(0)) >>> Type.index()
      MemRef.store(val, ptr, zero, loc: loc) >>> []
    end
  end

  defp ptr_type(elem_type, ctx) do
    layout =
      MLIR.CAPI.mlirStridedLayoutAttrGet(
        ctx,
        MLIR.CAPI.mlirShapedTypeGetDynamicStrideOrOffset(),
        1,
        Beaver.Native.array([1], Beaver.Native.I64)
      )

    Type.memref([:dynamic], elem_type, layout: layout, ctx: ctx)
  end

  # cast ptr to a pointer of the given element type with offset
  defp offset_ptr(ptr, elem_type, offset, ctx, blk, loc) do
    mlir ctx: ctx, blk: blk do
      d = MLIR.CAPI.mlirShapedTypeGetDynamicStrideOrOffset() |> Beaver.Native.to_term()
      static_offsets_or_sizes = Attribute.dense_array([d], Beaver.Native.I64, ctx: ctx)
      static_strides = Attribute.dense_array([1], Beaver.Native.I64, ctx: ctx)

      if MLIR.null?(static_offsets_or_sizes) do
        raise ArgumentError, "Failed to create dense array"
      end

      [_, offset_extracted, size, _stride] =
        MemRef.extract_strided_metadata(ptr, loc: loc) >>> :infer

      offset = Arith.addi(offset_extracted, offset, loc: loc) >>> Type.index()

      MemRef.reinterpret_cast(ptr, offset, size,
        operand_segment_sizes: Beaver.MLIR.ODS.operand_segment_sizes([1, 1, 1, 0]),
        static_offsets: static_offsets_or_sizes,
        static_sizes: static_offsets_or_sizes,
        static_strides: static_strides,
        loc: loc
      ) >>> ptr_type(elem_type, ctx)
    end
  end

  defintrinsic element_ptr(%MLIR.Type{} = elem_type, ptr, n) do
    %Opts{ctx: ctx, blk: blk, loc: loc} = __IR__

    t = MLIR.Value.type(ptr)
    elem_t = MLIR.CAPI.mlirShapedTypeGetElementType(t)

    if not MLIR.equal?(elem_t, elem_type) do
      raise ArgumentError,
            "Expected a pointer of type #{MLIR.to_string(elem_type)}, got #{MLIR.to_string(t)}"
    end

    mlir ctx: ctx, blk: blk do
      n =
        case n do
          i when is_integer(i) ->
            Index.constant(value: Attribute.index(i)) >>> Type.index()

          %MLIR.Value{} ->
            if Type.index?(MLIR.Value.type(n)) do
              n
            else
              Index.casts(n, loc: loc) >>> Type.index()
            end
        end

      offset_ptr(ptr, elem_type, n, ctx, blk, loc)
    end
  end

  @doc """
  Gets the element pointer of `elem_type` for the given base pointer `ptr` and index `n`.
  """
  defintrinsic element_ptr(%MLIR.Value{} = ptr, n) do
    t = MLIR.Value.type(ptr)

    if memref_ptr?(t) do
      quote do
        Charms.Pointer.element_ptr(
          unquote(MLIR.CAPI.mlirShapedTypeGetElementType(t)),
          unquote(ptr),
          unquote(n)
        )
      end
    else
      raise ArgumentError, "Pointer is not typed, use element_ptr/3 to specify the pointer type"
    end
  end

  defintrinsic element_type(%MLIR.Value{} = ptr) do
    t = MLIR.Value.type(ptr)

    if memref_ptr?(t) do
      MLIR.CAPI.mlirShapedTypeGetElementType(t)
    else
      raise ArgumentError, "Pointer is not typed, element_type/1 expects a typed pointer"
    end
  end

  @doc """
  Return the pointer type
  """
  defintrinsic t() do
    %Opts{ctx: ctx} = __IR__
    Beaver.Deferred.create(~t{!llvm.ptr}, ctx)
  end

  defintrinsic t(elem_t) do
    %Opts{ctx: ctx} = __IR__
    ptr_type(elem_t, ctx)
  end
end
