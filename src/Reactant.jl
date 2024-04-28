module Reactant

include("mlir/MLIR.jl")
include("XLA.jl")
include("utils.jl")

abstract type RArray{ElType,Shape,N} <: AbstractArray{ElType, N} end

@inline Base.eltype(::RArray{ElType,Shape}) where {ElType, Shape} = ElType
@inline Base.size(::RArray{ElType,Shape}) where {ElType, Shape} = Shape
@inline Base.ndims(::RArray{ElType,Shape, N}) where {ElType, Shape, N} = N
@inline Base.ndims(::Type{<:RArray{ElType,Shape, N}}) where {ElType, Shape, N} = N

@inline mlir_type(::RArray{ElType,Shape,N}) where {ElType, Shape, N} = MLIR.IR.TensorType(Shape, MLIR.IR.Type(ElType))

struct XLAArray{ElType,Shape,N} <: RArray{ElType, Shape, N}
end

mutable struct ConcreteRArray{ElType,Shape,N} <: RArray{ElType, Shape, N}
	data::XLA.AsyncBuffer
#	data::XLAArray{ElType, Shape, N}
end

function Base.convert(::Type{T}, X::ConcreteRArray{ElType, Shape, N}) where {T<:Array, ElType, Shape, N}
    data = Array{ElType, N}(undef, (reverse(Shape)...))
	XLA.await(X.data)
	buf = X.data.buffer
	GC.@preserve data buf begin
		XLA.BufferToHost(buf, pointer(data))
	end
    return data
    # XLA.from_row_major(data)
end

function Base.print_array(io::IO, X::ConcreteRArray)
	if X.data == XLA.AsyncEmptyBuffer
		println(io, "<Empty buffer>")
		return
	end
	Base.print_array(io, convert(Array, X))
end

function Base.show(io::IO, X::ConcreteRArray)
	if X.data == XLA.AsyncEmptyBuffer
		println(io, "<Empty buffer>")
		return
	end
	Base.show(io, convert(Array, X))
end


@inline function Base.getindex(a::ConcreteRArray{ElType, Shape}, args::Vararg{Int, N}) where {ElType, Shape, N}
	if a.data == XLA.AsyncEmptyBuffer
		throw("Cannot getindex from empty buffer")
	end
	XLA.await(a.data)
	if XLA.BufferOnCPU(a.data.buffer)
		buf = a.data.buffer
		GC.@preserve buf begin
			ptr = Base.unsafe_convert(Ptr{ElType}, XLA.UnsafeBufferPointer(buf))
			start = 0
			for i in 1:N
				start *= Shape[N-i+1]
				start += (args[N-i+1]-1)
				# start *= Shape[i]
				# start += (args[i]-1)
			end
			start += 1
			return unsafe_load(ptr, start)
		end
	end
	return convert(Array, X)[args...]
end

@inline function ConcreteRArray(data::Array{ElType, N}; client=XLA.default_backend[], idx=XLA.default_device_idx[]) where {ElType, N}
	device = XLA.ClientGetDevice(client, idx)
	ConcreteRArray{ElType, size(data), N}(XLA.AsyncBuffer(XLA.ArrayFromHostBuffer(client, data, device), nothing))
	# ConcreteRArray{ElType, size(data), N}(XLA.AsyncBuffer(XLA.ArrayFromHostBuffer(client, XLA.to_row_major(data), device), nothing))
end

@inline ConcreteRArray(data::T) where {T <: Number} = ConcreteRArray{T, (), 0}(data)

mutable struct TracedRArray{ElType,Shape,N} <: RArray{ElType, Shape, N}
	paths::Tuple
	mlir_data::Union{Nothing,MLIR.IR.Value}
	function TracedRArray{ElType,Shape,N}(paths::Tuple, mlir_data::Union{Nothing,MLIR.IR.Value}) where {ElType, Shape, N}
		if mlir_data !== nothing
			@assert size(MLIR.IR.type(mlir_data)) == Shape
		end
		new{ElType,Shape,N}(paths, mlir_data)
	end
end

function Base.promote_rule(A::Type{TracedRArray{T, Shape, N}}, B::Type{TracedRArray{S, Shape, N}}) where {T, S, Shape, N}
    TracedRArray{Base.promote_type(T, S), Shape, N}
end

function Base.promote_rule(A::Type{T}, B::Type{TracedRArray{S, Shape, N}}) where {T, S, Shape, N}
	TracedRArray{Base.promote_type(T, S), Shape, N}
end

function Base.show(io::IO, X::TracedRArray{ElType, Shape, N}) where {ElType, Shape, N}
	print(io, "TracedRArray{", ElType, ",", Shape, ",", N, "N}(", X.paths, ", ", X.mlir_data, ")")
end

include("overloads.jl")

using Enzyme

@inline val_value(::Val{T}) where T = T

@enum TraceMode begin
	ConcreteToTraced = 1
	TracedTrack = 2
	TracedToConcrete = 3
	ArrayToConcrete = 4
	TracedSetPath = 5
 end

@inline is_concrete_tuple(x::T2) where T2 = (x <: Tuple) && !(x === Tuple) && !(x isa UnionAll)
@inline function traced_type(val::Type{T}, seen::ST, ::Val{mode}) where {ST,T, mode}
	if T <: ConcreteRArray
		if mode == ConcreteToTraced
			@inline base_typet(TV::TT) where TT <: UnionAll = UnionAll(TV.var, base_typet(TV.body))
			@inline base_typet(TV::TT) where TT <: DataType = TracedRArray{TV.parameters...}
			return base_typet(T)
		elseif mode == TracedToConcrete
			return T
		else
			throw("Abstract RArray cannot be made concrete")
		end
	end
	if T <: TracedRArray
		if mode == ConcreteToTraced
			throw("TracedRArray $T cannot be traced")
		elseif mode == TracedToConcrete
			@inline base_typec(TV::TT) where TT <: UnionAll = UnionAll(TV.var, base_typec(TV.body))
			@inline base_typec(TV::TT) where TT <: DataType = ConcreteRArray{TV.parameters...}
			return base_typec(T)
		elseif mode == TracedTrack || mode == TracedSetPath
			return T
		else
			throw("Abstract RArray $T cannot be made concrete in mode $mode")
		end
	end

	if T <: XLAArray
		throw("XLA $T array cannot be traced")
	end
	if T <: RArray
		return T
	end


    if T === Any
        return T
    end

    if T === Symbol
        return T
    end
    
    if T <: Val
    	val = val_value(T)
    	if traced_type(typeof(val), seen, Val(mode)) == typeof(val)
    		return T
    	end
		throw("Val type $T cannot be traced")
    end

    if T === Union{}
        return T
    end

    if T == Nothing
        return T
    end

    if T == Char
        return T
    end

    if T <: Complex && !(T isa UnionAll)
        return Complex{traced_type(Enzyme.Compiler.ptreltype(T), seen, Val(mode))}
    end

    if T <: AbstractFloat
        return T
    end

    if T <: Ptr
    	return Ptr{traced_type(Enzyme.Compiler.ptreltype(T), seen, Val(mode))}
    end

    if T <: Core.LLVMPtr
    	return Core.LLVMPtr{traced_type(Enzyme.Compiler.ptreltype(T), seen, Val(mode))}
    end

    if T <: Base.RefValue
    	return Base.RefValue{traced_type(Enzyme.Compiler.ptreltype(T), seen, Val(mode))}
    end

    if T <: Array
		if mode == ArrayToConcrete && eltype(T) <: AbstractFloat
			return (ConcreteRArray{eltype(T), Shape, ndims(T)} where Shape)
		else
	    	return Array{traced_type(Enzyme.Compiler.ptreltype(T), seen, Val(mode)), ndims(T)}
		end
    end

    if T <: Integer
        return T
    end

    if Enzyme.Compiler.isghostty(T) || Core.Compiler.isconstType(T)
        return T
    end

    if T <: Function
        return T
    end

    if T <: DataType
        return T
    end
    if T <: Module
        return T
    end
    if T <: AbstractString
        return T
    end

    # unknown number of fields
    if T isa UnionAll
        aT = Base.argument_datatype(T)
        if aT === nothing
        	throw("Unhandled type $T")
        end
        if datatype_fieldcount(aT) === nothing
        	throw("Unhandled type $T")
        end
    end

    if T isa Union
    	return Union{traced_type(T.a, seen, Val(mode)), traced_type(T.b, seen, Val(mode))}
    end

    # if abstract it must be by reference
    if Base.isabstracttype(T)
    	throw("Unhandled abstract type $T")
    end

    @assert !Base.isabstracttype(T)

    if !(Base.isconcretetype(T) || is_concrete_tuple(T) || T isa UnionAll)
        throw(AssertionError("Type $T is not concrete type or concrete tuple"))
    end

    if is_concrete_tuple(T) && any(T2 isa Core.TypeofVararg for T2 in T.parameters)
        Tuple{((T2 isa Core.TypeofVararg ? Any : T2) for T2 in T.parameters)...,}
        throw(AssertionError("Type tuple of vararg $T is not supported"))
    end

    if is_concrete_tuple(T)
    	return Tuple{(traced_type(T2, seen, Val(mode)) for T2 in T.parameters)...}
    end

    if T <: NamedTuple
    	@inline tup_name(::Type{NamedTuple{A, B}}) where {A, B} = A
    	@inline tup_val(::Type{NamedTuple{A, B}}) where {A, B} = B
    	return NamedTuple{tup_name(T), traced_type(tup_val(T), seen, Val(mode))}
    end

    if T <: Dict
    	@inline dict_name(::Type{Dict{A, B}}) where {A, B} = A
    	@inline dict_val(::Type{Dict{A, B}}) where {A, B} = B
    	return Dict{dict_name(T), traced_type(dict_val(T), seen, Val(mode))}
    end

    if T <: IdDict
    	@inline iddict_name(::Type{IdDict{A, B}}) where {A, B} = A
    	@inline iddict_val(::Type{IdDict{A, B}}) where {A, B} = B
    	return IdDict{iddict_name(T), traced_type(iddict_val(T), seen, Val(mode))}
    end

    if Val(T) ∈ seen
        return seen[T]
    end

    seen = (Val(T), seen...)

    changed = false
    subTys = Type[]
    for f in 1:fieldcount(T)
        subT = fieldtype(T, f)
        subTT = traced_type(subT, seen, Val(mode))
        changed |= subT != subTT
        push!(subTys, subTT)
    end

    if !changed
    	return T
    end

    subParms = []
    for SST in T.parameters
    	if SST isa Type
			TrT = traced_type(SST, seen, Val(mode))
    		push!(subParms, TrT)
    	else
    		push!(subParms, SST)
    	end
    end

    TT2 = Core.apply_type(T.name.wrapper, subParms...)
    if fieldcount(T) == fieldcount(TT2)
	    legal = true
	    for f in 1:fieldcount(T)
	        subT = fieldtype(T, f)
	        subT2 = fieldtype(TT2, f)
	        subTT = traced_type(subT, seen, Val(mode))
	        legal &= subT2 == subTT
	    end
	    if legal
	    	return TT2
	    end
	end

	name = Symbol[]

	return NamedTuple{fieldnames(T), Tuple{subTys...}}
end

function append_path(path, i)
	(path..., i)
end

@inline function make_tracer(seen::IdDict, prev::RT, path, mode, data) where {RT}
    if haskey(seen, prev)
        return seen[prev]
    end
    TT = traced_type(RT, (), Val(mode))
    @assert !Base.isabstracttype(RT)
    @assert Base.isconcretetype(RT)
    nf = fieldcount(RT)

	if TT <: NamedTuple
        changed = false
		subs = []
        for i in 1:nf
			xi = getfield(prev, i)
			xi2 = make_tracer(seen, xi, append_path(path, i), mode, data)
			if xi !== xi2
				changed = true
			end
			push!(subs, xi2)
        end
		if !changed
			seen[prev] = prev
			return prev
		end
		tup = (subs...,)
		@show TT, subs, tup
		return NamedTuple{TT.parameters[1], typeof(tup)}(tup)
	end
    
    if ismutabletype(TT)
        y = ccall(:jl_new_struct_uninit, Any, (Any,), TT)
        seen[prev] = y
        changed = false
        for i in 1:nf
            if isdefined(prev, i)
                xi = getfield(prev, i)
                xi2 = make_tracer(seen, xi, append_path(path, i), mode, data)
                if xi !== xi2
                	changed = true
                end
                ccall(:jl_set_nth_field, Cvoid, (Any, Csize_t, Any), y, i-1, xi2)
            end
        end
        if !changed
        	seen[prev] = prev
        	return prev
        end
        return y
    end
    
    if nf == 0
        return prev
    end

    flds = Vector{Any}(undef, nf)
    changed = false
    for i in 1:nf
        if isdefined(prev, i)
            xi = getfield(prev, i)
            xi2 = make_tracer(seen, xi, append_path(path, i), mode, data)
            if xi !== xi2
            	changed = true
            end
            flds[i] = xi2
        else
            nf = i - 1 # rest of tail must be undefined values
            break
        end
    end    
    if !changed
    	seen[prev] = prev
    	return prev
    end
    y = ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), TT, flds, nf)
    seen[prev] = y
    return y
end

@inline function make_tracer(seen::IdDict, prev::ConcreteRArray{ElType, Shape, N}, path, mode, data) where {ElType, Shape, N}
	if mode == ArrayToConcrete
		return prev
	end
	if mode != ConcreteToTraced
		throw("Cannot trace concrete")
	end
    if haskey(seen, prev)
        return seen[prev]::TracedRArray{ElType, Shape, N}
    end
	@assert N isa Int
    res = TracedRArray{ElType, Shape, N}((path,), nothing)
    seen[prev] = res
    return res
end

@inline function make_tracer(seen::IdDict, prev::TracedRArray{ElType, Shape, N}, path, mode, data) where {ElType, Shape, N}
	if mode == ConcreteToTraced
		throw("Cannot trace existing trace type")
	end
	if mode == TracedTrack
		prev.paths = (prev.paths..., path)
	    if !haskey(seen, prev)
	        return seen[prev] = prev
	    end
	    return prev
	end
	if mode == TracedSetPath
	    if haskey(seen, prev)
	        return seen[prev]
	    end
	    res = TracedRArray{ElType, Shape, N}((path,), prev.mlir_data)
	    seen[prev] = res
	end

	if mode == TracedToConcrete
	    if haskey(seen, prev)
	        return seen[prev]::ConcreteRArray{ElType, Shape, N}
	    end
	    res = ConcreteRArray{ElType, Shape, N}(XLA.AsyncEmptyBuffer)
	    seen[prev] = res
	    return res	    
	end

	throw("Cannot Unknown trace mode")
end

@inline function make_tracer(seen::IdDict, prev::RT, path, mode, data) where {RT<:AbstractFloat}
    return prev
end

@inline function make_tracer(seen::IdDict, prev::Complex{RT}, path, mode, data) where {RT}
    return Complex(make_tracer(seen, prev.re, append_path(path, :re), mode, data), make_tracer(seen, prev.im, append_path(path, :im), mode, data))
end

@inline function make_tracer(seen::IdDict, prev::RT, path, mode, data) where {RT<:Array}
    if haskey(seen, prev)
        return seen[prev]
    end
	if mode == ArrayToConcrete && eltype(RT) <: AbstractFloat
		return seen[prev] = ConcreteRArray(prev)
	end
    TT = traced_type(eltype(RT), (), Val(mode))
    newa = Array{TT, ndims(RT)}(undef, size(prev))
    seen[prev] = newa
    same = true
    for I in eachindex(prev)
        if isassigned(prev, I)
            pv = prev[I]
            nv = make_tracer(seen, pv, append_path(path, I), mode, data)
            if pv !== nv
            	same = false
            end
            @inbounds newa[I] = nv
        end
    end
    if same
    	seen[prev] = prev
    	return prev
    end
    return newa
end

@inline function make_tracer(seen::IdDict, prev::RT, path, mode, data) where {RT<:Tuple}
    return ((make_tracer(seen, v, append_path(path, i), mode, data) for (i, v) in enumerate(prev))...,)
end

@inline function make_tracer(seen::IdDict, prev::NamedTuple{A,RT}, path, mode, data) where {A, RT}
    return NamedTuple{A, traced_type(RT, (), Val(mode))}(
	    ((make_tracer(seen, getfield(prev, name), append_path(path, name), mode, data) for name in A)...,)
    )
end

@inline function make_tracer(seen::IdDict, prev::Core.Box, path, mode, data)
    if haskey(seen, prev)
        return seen[prev]
    end
    prev2 = prev.contents
    tr = make_tracer(seen, prev2, append_path(path, :contents), mode, data)
    if tr == prev2
	    seen[prev] = prev
    	return prev
    end
    res = Core.Box(tr)
    seen[prev] = res
    return res
end

function generate_jlfunc(concrete_result, client, mod, Nargs, linear_args, linear_results, preserved_args)
	args = ntuple(Val(Nargs)) do i
		Base.@_inline_meta
		Symbol("arg_$i")
	end

	linearized_args = Union{Symbol,Expr}[]

	for arg in linear_args
        paths = ((p for p in arg.paths if p[1] == "args")...,)
		path = if length(paths) == 1
			paths[1]
		else
            throw("Invalid path duplication $(arg.paths) into $(paths)")
        end
		res = Symbol("arg_$(path[2])")
		for p in path[3:end]
			res = :(getfield($res, $p))
		end
		res = :(XLA.synced_buffer($res.data).buffer)
		push!(linearized_args, res)
	end

	concretize = Expr[]
	for (idx, res) in enumerate(linear_results)
		push!(concretize, :(
			$(Symbol("concrete_res_$(idx)")) = linearized_results[$idx]
		))
	end

	delinearized_results = Expr[]

	for (idx, result) in enumerate(linear_results)
        paths = ((p for p in result.paths if p[1] != "args")...,)
		for path in paths
			if path[1] == "result"
				res = Symbol("result")
				path = path[2:end]
			else
				if path[1] != "resargs"
                    @show idx #, result
                    @show paths
                    @show path
                end
				@assert path[1] == "resargs"
				res = Symbol("arg_$(path[2])")
				path = path[3:end]
			end
			for p in path
				res = :(getfield($res, $p))
			end
			res = :($res.data = $(Symbol("concrete_res_$(idx)")) )
			push!(delinearized_results, res)
		end
	end

	for (result, arg_idx) in preserved_args
		for path in result.paths
			arg = linear_args[arg_idx+1]
            argpath = only((p for p in arg.paths if p[1] == "args"))

			if path[1] == "result"
				res = Symbol("result")
				path = path[2:end]
			else
				@assert path[1] == "resargs" || path[1] == "args"
				# We can optimize cases where we set the arg to itself
				if path[2:end] == argpath[2:end]
					continue
				end
                @show path, argpath
				res = Symbol("arg_$(path[2])")
				path = path[3:end]
			end
			for p in path
				res = :(getfield($res, $p))
			end

			argres = Symbol("arg_$(argpath[2])")
			for p in argpath[3:end]
				argres = :(getfield($argres, $p))
			end

			res = :($res.data = $argres.data )
			push!(delinearized_results, res)
		end
	end

	exec = XLA.Compile(client, mod)


    donated_args_set = zeros(UInt8, length(linearized_args))
    preserved_argnums = [i for (_, i) in preserved_args]
	for (i, val) in enumerate(linear_args)
		if !in(i, preserved_args)
			donated_args_set[i] = 1
		end
	end

    exec_call = if length(linear_results) == 0
        :()
    else
        :(
			linearized_results = XLA.ExecutableCall($exec, [$(linearized_args...)], $donated_args_set,  Val($(length(linear_results))))
        )
    end
	func = quote
        ($(args...),) -> begin
            $exec_call
			$(concretize...)
			result = $concrete_result
			$(delinearized_results...)
			return result
		end
	end
	return eval(func)
end

const registry = Ref{MLIR.IR.DialectRegistry}()
function __init__()
	registry[] = MLIR.IR.DialectRegistry()
	@ccall MLIR.API.mlir_c.InitializeRegistryAndPasses(registry[]::MLIR.API.MlirDialectRegistry)::Cvoid
end

function compile(f::FTy, args::VAT; pipeline_options="", client=nothing) where {FTy, VAT <: Tuple}
	N = length(args)
	ctx = MLIR.IR.Context()
	Base.append!(registry[], context=ctx)
	@ccall MLIR.API.mlir_c.RegisterDialects(ctx::MLIR.API.MlirContext)::Cvoid
	MLIR.IR.context!(ctx) do
		mod = MLIR.IR.Module(MLIR.IR.Location())

		fnwrapped, func2, traced_result, result, seen_args, ret, linear_args, in_tys, linear_results = make_mlir_fn(mod, f, args, (), "main", true)
		@assert !fnwrapped

		concrete_seen = IdDict()

		concrete_result = make_tracer(concrete_seen, traced_result, ("result",), TracedToConcrete, #=data=#nothing)

		if client === nothing
			if length(linear_args) > 0
				for (k, v) in seen_args
					if !(v isa TracedRArray)
						continue
					end
					client = XLA.client(k.data)
				end
			end
			if client === nothing
				client = XLA.default_backend[]
			end
		end
		
		XLA.RunPassPipeline("inline{default-pipeline=canonicalize max-iterations=4},canonicalize,cse,enzyme-hlo-unroll,canonicalize,cse,enzyme-hlo-opt{passses=24575},cse", mod)

		preserved_args = Tuple{TracedRArray, Int}[]
        results = [MLIR.IR.operand(ret, i) for i in 1:MLIR.IR.noperands(ret)]
        nresults = MLIR.IR.Value[]
		linear_results2 = TracedRArray[]
        for (i, op) in enumerate(results)
            if !MLIR.IR.is_block_arg(op)
                push!(nresults, op)
                push!(linear_results2, linear_results[i])
                continue
            end
            push!(preserved_args, (linear_results[i], MLIR.IR.block_arg_num(op)))
        end
        fnbody = MLIR.IR.block(ret)
        MLIR.API.mlirOperationDestroy(ret.operation)
        ret.operation = MLIR.API.MlirOperation(C_NULL)
		MLIR.IR.block!(fnbody) do
			MLIR.Dialects.func.return_(nresults)
        end

        out_tys2 = [MLIR.IR.type(a) for a in nresults]

        func3 = MLIR.Dialects.func.func_(; sym_name="main", function_type=MLIR.IR.FunctionType(in_tys, out_tys2), body=MLIR.IR.Region())
		MLIR.API.mlirRegionTakeBody(MLIR.IR.region(func3, 1), MLIR.IR.region(func2, 1))

		push!(MLIR.IR.body(mod), func3)
		
        MLIR.API.mlirOperationDestroy(func2.operation)
        func2.operation = MLIR.API.MlirOperation(C_NULL)
        
        # println(string(mod))

        return generate_jlfunc(concrete_result, client, mod, N, linear_args, linear_results2, preserved_args)
	end
end


end # module
