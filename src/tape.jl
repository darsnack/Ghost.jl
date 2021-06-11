abstract type AbstractOp end

########################################################################
#                             VARIABLE                                 #
########################################################################

"""
Variable represents a reference to an operation on a tape.
Variables can be used to index tape or keep reference to
a specific operation on the tape.

Variables can be:

* free, created as V(id) - used for indexing into tape
* bound, created as V(op) - used to keep a robust reference
  to an operation on the tape
"""
mutable struct Variable
    _id::Union{<:Integer,Nothing}
    _op::Union{AbstractOp,Nothing}
end

Variable(id::Integer) = Variable(id, nothing)
Variable(op::AbstractOp) = Variable(nothing, op)

Base.show(io::IO, v::Variable) = print(io, "%$(v.id)")


function Base.getproperty(v::Variable, p::Symbol)
    if p == :id
        if v._op !== nothing
            # variable bound to a specific operation on a tapea
            return v._op.id
        else
            # free variable with only ID
            return v._id
        end
    else
        return getfield(v, p)
    end
end

function Base.setproperty!(v::Variable, p::Symbol, x)
    if p == :id
        if v._op !== nothing
            # variable bound to a specific operation on a tapea
            v._op.id = x
        else
            # free variable with only ID
            v.id = x
        end
    else
        return setfield!(v, p, x)
    end
end


function Base.:(==)(v1::Variable, v2::Variable)
    # variables are equal if:
    # * both are bound to the same operation, or
    # * both are unbound and their IDs are equal
    return v1._op === v2._op && v1.id == v2.id
end

Base.hash(v::Variable, h::UInt) = hash(v.id, hash(v._op, h))


const V = Variable



########################################################################
#                            OPERATIONS                                #
########################################################################

function Base.getproperty(op::AbstractOp, f::Symbol)
    if f == :typ
        return typeof(op.val)
    elseif f == :var
        return Variable(nothing, op)
    else
        getfield(op, f)
    end
end

## Input

mutable struct Input <: AbstractOp
    id::Int
    val::Any
end

Input(val::Any) = Input(0, val)

Base.show(io::IO, op::Input) = print(io, "inp %$(op.id)::$(op.typ)")


## Constant

mutable struct Constant <: AbstractOp
    id::Int
    typ::Type
    val
end


Constant(id::Int, val) = Constant(id, typeof(val), val)
Constant(val) = Constant(0, typeof(val), val)
Base.show(io::IO, op::Constant) = print(io, "const %$(op.id) = $(op.val)::$(op.typ)")


## Call

mutable struct Call <: AbstractOp
    id::Int
    val::Any
    fn::Union{Function,Type,Variable}
    args::Vector{Any}   # vector of Variables or const values
end


pretty_type_name(T) = string(T)
pretty_type_name(T::Type{<:Broadcast.Broadcasted}) = "Broadcasted{}"

function Base.show(io::IO, op::Call)
    arg_str = join(["$v" for v in op.args], ", ")
    typ_str = pretty_type_name(op.typ)
    print(io, "%$(op.id) = $(op.fn)($arg_str)::$typ_str")
end


"""
Helper function to map a function only to Variable arguments of a Call
leaving constant values as is
"""
function map_vars(fn::Function, args::Union{Vector,Tuple})
    return map(v -> v isa Variable ? fn(v) : v, args)
end


"""
    mkcall(fn, args...; val=missing)

Convenient constructor for Call operation. If val is `missing` (default)
and call value can be calculated from (bound) variables and constants,
they are calculated. To prevent this behavior, set val to some neutral value.
"""
function mkcall(fn::Union{Function,Type,Variable}, args...; val=missing)
    fargs = (fn, args...)
    calculable = all(
        a -> !isa(a, Variable) ||                      # not variable
        (a._op !== nothing && a._op.val !== missing),  # bound variable
        fargs
    )
    if val === missing && calculable
        fargs_ = map_vars(v -> v._op.val, fargs)
        fn_, args_ = fargs_[1], fargs_[2:end]
        val_ = fn_(args_...)
    else
        val_ = val
    end
    return Call(0, val_, fn, [args...])
end


########################################################################
#                                 TAPE                                 #
########################################################################


mutable struct Tape{C}
    # linearized execution graph
    ops::Vector{<:AbstractOp}
    # result variable
    result::Variable
    # for subtapes - parent tape
    parent::Union{Tape,Nothing}
    # tape metadata (depends on the context)
    meta::Dict
    # application-specific context
c::C
end

Tape(c::C) where C = Tape(AbstractOp[], Variable(0), nothing, Dict(), c)
# by default context is just a Dict{Any, Any}
Tape() = Tape(Dict{Any,Any}())


function Base.show(io::IO, tape::Tape{C}) where C
    println(io, "Tape{$C}")
    for op in tape.ops
        println(io, "  $op")
    end
end


function Base.getproperty(tape::Tape, p::Symbol)
    if p == :retval
        return tape[tape.result].val
    else
        return getfield(tape, p)
    end
end


inputs(tape::Tape) = [V(op) for op in tape.ops if op isa Input]
function inputs!(tape::Tape, vals...)
    @assert(isempty(tape) || length(inputs(tape)) == length(vals),
            "This tape contains $(length(inputs(tape))) inputs, but " *
            "$(length(vals)) value(s) were provided")
    if isempty(tape)
        # initialize inputs
        for val in vals
            push!(tape, Input(val))
        end
    else
        # rewrite input values
        for (i, val) in enumerate(vals)
            tape[V(i)].val = val
        end
    end
    return [V(op) for op in tape.ops[1:length(vals)]]
end

Base.getindex(tape::Tape, v::Variable) = tape.ops[v.id]

function Base.setindex!(tape::Tape, op::AbstractOp, v::Variable)
    op.id = v.id
    tape.ops[v.id] = op
    v._op = op   # bind to op, overriding v.id
end

Base.lastindex(tape::Tape) = lastindex(tape.ops)
Base.length(tape::Tape) = length(tape.ops)
Base.iterate(tape::Tape) = iterate(tape.ops)       # exclude inputs?
Base.iterate(tape::Tape, s) = iterate(tape.ops, s)


"""
    push!(tape::Tape, op::AbstractOp)

Push a new operation to the end of the tape.
"""
function Base.push!(tape::Tape, op::AbstractOp)
    new_id = length(tape) + 1
    op.id = new_id
    push!(tape.ops, op)
    return V(op)
end


"""
    insert!(tape::Tape, idx::Integer, ops::AbstractOp...)

Insert new operations into tape starting from position idx.
"""
function Base.insert!(tape::Tape, idx::Integer, ops::AbstractOp...)
    num_new_ops = length(ops)
    old_ops = tape.ops
    new_ops = Vector{AbstractOp}(undef, length(tape) + num_new_ops)
    # copy old ops before insertion point
    for i = 1:idx - 1
        new_ops[i] = old_ops[i]
    end
    # insert target ops, assign ids
    for i = 1:num_new_ops
        id = idx + i - 1
        new_ops[id] = ops[i]
        new_ops[id].id = id
    end
    # insert the rest of old ops
    for i = idx:length(old_ops)
        id = i + num_new_ops
        new_ops[id] = old_ops[i]
        new_ops[id].id = id
    end
    tape.ops = new_ops
    return [V(op) for op in ops]
end


"""
    replace!(tape, idx => [ops...]; rebind_to)

Replace operation at specified index with 1 or more other operations,
rebind variables in the reminder of the tape to ops[rebind_to].
"""
function Base.replace!(tape::Tape, idx_ops::Pair{<:Integer,<:Union{Tuple,Vector}};
                       rebind_to=length(idx_ops[2]))
    idx, ops = idx_ops
    tape[V(idx)] = ops[1]
    if idx < length(tape)
        insert!(tape, idx + 1, ops[2:end]...)
    else
        for op in ops[2:end]
            push!(tape, op)
        end
    end
    st = Dict(idx => ops[rebind_to].id)
    rebind!(tape, st; from=idx + length(ops))
    return ops[rebind_to]
end


########################################################################
#                       SPECIAL OPERATIONS                             #
########################################################################

## Loop

mutable struct Loop <: AbstractOp
    id::Int
    parent_inputs::Vector{Variable}
    condition::Variable
    cont_vars::Vector{Variable}
    exit_vars::Vector{Variable}
    subtape::Tape
    val::Any
end

function Base.show(io::IO, loop::Loop)
    input_str = join(map(string, loop.parent_inputs), ", ")
    print(io, "%$(loop.id) = Loop($input_str)")
end

###############################################################################
#                                 REBIND                                      #
###############################################################################

"""Returned version of the var bound to the tape op"""
bound(tape::Tape, v::Variable) = Variable(tape[v])


"""
    rebind!(tape::Tape, op, st::Dict)
    rebind!(tape::Tape, st::Dict; from, to)

Rebind all variables according to substitution table. Example:

    tape = Tape()
    v1, v2 = inputs!(tape, nothing, 3.0, 5.0)
    v3 = push!(tape, mkcall(*, v1, 2))
    st = Dict(v1.id => v2.id)
    rebind!(tape, st)
    @assert tape[v3].args[1].id == v2.id

See also: rebind_context!()
"""
function rebind!(tape::Tape, v::Variable, st::Dict)
    if haskey(st, v.id)
        # rebind to a new op
        v._op = tape[V(st[v.id])]
end
end

rebind!(::Tape, ::Input, ::Dict) = ()
rebind!(::Tape, ::Constant, ::Dict) = ()

function rebind!(tape::Tape, op::Call, st::Dict)
    for v in op.args
        if v isa Variable
            rebind!(tape, v, st)
        end
    end
    return op
end


"""
    rebind_context!(tape::Tape, st::Dict)
Rebind variables in the tape's context according to substitution table.
By default does nothing, but can be overwitten for specific Tape{C}
"""
rebind_context!(tape::Tape, st::Dict) = ()


function rebind!(tape::Tape, st::Dict; from=1, to=length(tape))
    for id = from:to
        rebind!(tape, tape[V(id)], st)
    end
    rebind!(tape, tape.result, st)
    rebind_context!(tape, st)
    return tape
end


########################################################################
#                              EXECUTION                               #
########################################################################

exec!(::Tape, ::Input) = ()
exec!(::Tape, ::Constant) = ()

function exec!(tape::Tape, op::Call)
    fn = op.fn isa V ? tape[op.fn].val : op.fn
    arg_vals = map_vars(v -> tape[v].val, op.args)
    op.val = fn(arg_vals...)
end


"""
Collect variables which will be used at loop exit if it happens
at this point on tape.
"""
function loop_exit_vars_at_point(op::Loop, id::Int)
    input_vars = inputs(op.subtape)
    exit_idxs = findall(v -> v in op.exit_vars, op.cont_vars)
    vars = Vector{Variable}(undef, length(exit_idxs))
    for (i, idx) in enumerate(exit_idxs)
        if id > op.cont_vars[idx].id
            # if condition is checked after this continue var is changed,
            # use continue var
            vars[i] = op.cont_vars[idx]
        else
            # otherwise use input var
            vars[i] = input_vars[idx]
        end
    end
    return vars
end


function exec!(tape::Tape, op::Loop)
    subtape = op.subtape
    # initialize inputs
    inputs!(subtape, [tape[v].val for v in op.parent_inputs]...)
    # run the loop strictly while continue condition is true
    # note that subtape execution may finish before the full
    # iteration is done
    cond_var = op.condition
    vi0 = length(op.parent_inputs) + 1
    vi = vi0
    while true
        # @show vi
        # @show subtape[V(1)].val
        # @show subtape[V(2)].val
        # @show subtape[V(7)].val
        # sleep(1)
        exec!(subtape, subtape[V(vi)])
        if vi == cond_var.id && subtape[V(vi)].val == false
            actual_exit_vars = loop_exit_vars_at_point(op, vi)
            op.val = ([v._op.val for v in actual_exit_vars]...,)
            break
        end
        vi += 1
        if vi > length(subtape)
            vi = vi0
            inputs!(subtape, [subtape[v].val for v in op.cont_vars]...)
        end
    end
    # # exit_var is special - it's a tuple combining all the exit variables
    # # since it doesn't exist in the original code, it may be not executed
    # # by loop logic at the last iteration; hence, we execute it manually
    # exec!(subtape, subtape[op.exit_var])
    # op.val = subtape[op.exit_var].val
end


function play!(tape::Tape, args...; debug=false)
    for (i, val) in enumerate(args)
        @assert(tape[V(i)] isa Input, "More arguments than the original function had")
        tape[V(i)].val = val
    end
    for op in tape
        if debug
            println(op)
        end
        exec!(tape, op)
    end
    return tape[tape.result].val
end


########################################################################
#                                 UTILS                                #
########################################################################

function call_signature(tape::Tape, op::Call)
    farg_vals = map_vars(v -> tape[v].val, [op.fn, op.args...])
    return Tuple{map(typeof, farg_vals)...}
end
