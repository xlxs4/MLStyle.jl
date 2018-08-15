module Match
using MLStyle.Err
using MLStyle.Private

export @match, @def, Pattern, Case, Failed, failed, PatternDef, pattern_match, app_pattern_match, register_app_pattern, register_meta_pattern

struct Failed end
failed = Failed()

struct Pattern
    shape
    guard
end

struct Case
    patterns :: Vector{Pattern}
    body
end


# """
# e.g:
# register_meta_pattern((expr :: Expr) -> <conditional>) do  expr, guard, tag, mod
#   <return quote>
# end
# """
global meta_dispatchers = Vector{Tuple{Function, Function}}()

# """
# e.g
#
# register_app_pattern(ty) do args, guard, tag, mod
#     <return quote>
# end
# where `ty` is constructor or any other custom pattern(see @pattern)
# """
global app_dispatchers = Dict{Any, Function}()


global _count = 0
function mangling(apply, repr_ast)
    global _count = _count + 1
    let symbol = Symbol("<", repr(repr_ast), ".", _count, ">")
        ret = apply(symbol)
        global _count = _count - 1
        ret
    end
end

@inline function collect_guard(arg)
    if isa(arg, Expr) && arg.head == :curly
    let args = arg.args
        Pattern(args[1],
                Expr(:block,
                     reduce( (a, b) -> Expr(:&&, a, b), args[2:end])
                     ))
    end
    else
        Pattern(arg, nothing)
    end
end

function collect_fallthrough(c :: Channel, arg)

    if isa(arg, Expr) && arg.head == :call && arg.args[1] == :|

        let nested = arg.args[2:end-1], last = collect_guard(arg.args[end])

            if isempty(nested)
                put!(c, last)
            else
                foreach(nested) do n
                    collect_fallthrough(c, n)
                end
                put!(c, last)
            end

        end

    else
        put!(c, collect_guard(arg))
    end
end

function collect_fallthrough(arg)
    Channel(c -> collect_fallthrough(c, arg))
end

_warned = false
function merge_cases(cases :: Vector{Case})

    global _warned
    if !_warned
        @warn "Pattern optimization not implemented yet."
        _warned = true
    end

    cases
end


pattern_match_maker(tag :: Symbol, case :: Case, mod :: Module) =
    if isempty(case.patterns)
        InternalException("Internal Error 0") |> throw
    else let body = case.body,
             cond = map(case.patterns) do pattern
                    pattern_match(pattern.shape, pattern.guard, tag, mod)
                    end |>
                    function (last)
                        reduce((a, b) -> Expr(:||, a, b), last)
                    end
        quote
            if $cond
                $(case.body)
            else
                $failed
            end
        end
        end
    end

function make_case(arg)
    if !(arg.head == :call && arg.args[1] == :(=>))
            SyntaxError("A case should be something like <pattern> => <body>") |> throw
    end

    let args = arg.args, pattern = args[2], body = args[3]
        Case(append!([], collect_fallthrough(pattern)), body)
    end
end

function make_cases(args)
    map(args) do arg
        if isa(arg, LineNumberNode)
            arg
        else
            make_case(arg)
        end
    end
end

function make_match_body(
                tag,
                tag_sym,
                mod :: Module,
                cases)

    final = quote
                throw(($InternalException)("Non-exhaustive pattern found!"))
            end
    mangled = Symbol("case", ".", "test")

    foldr(cases, init=final) do case, last
        if isa(case, LineNumberNode)
            Expr(:block, case, last)
        else
        pattern_match_maker(tag_sym, case, mod) |>
        function (expr)
            quote
                let $mangled =
                    let
                        $expr
                    end
                if $mangled === $failed
                    $last
                else
                    $mangled
                end
                end
            end
        end
        end

    end |>

    function (quoted)
        quote
          let $tag_sym = $tag
            $quoted
          end
        end
    end

end



macro def(fn_name, pattern_def)
    if !isa(pattern_def, Expr) || !(pattern_def.head in (:braces, :bracescat, :block))
        SyntaxError("Invalid leading marker of match body.") |> throw
    end

    mangling(fn_name) do arg_prefix

        erl_dispatcher = Dict()
        cases = make_cases(filter(it -> !isa(it, LineNumberNode), pattern_def.args))
        new_cases = []

        foreach(cases) do case
            if length(case.patterns) == 1
                append!(new_cases, map(pat -> Case([pat], case.body), case.patterns))
            else
                push!(new_cases, case)
            end
        end

        foreach(new_cases) do case
            dispatch_key =
                begin
                    pattern = case.patterns[1]
                    if !(isa(pattern.shape, Expr) && pattern.shape.head == :tuple)
                        1
                    else
                        length(pattern.shape.args)
                    end
                end

            dispatch_value = get(erl_dispatcher, dispatch_key) do
                erl_dispatcher[dispatch_key] = []
            end

            push!(dispatch_value, case)

        end

        map(collect(erl_dispatcher)) do (argnum, cases)
            map(1:argnum) do arg_idx
                Symbol(arg_prefix, "[", arg_idx, "]")
            end |>
            function (args)
                body =
                    if length(args) > 1
                        make_match_body(Expr(:tuple, args...), arg_prefix, __module__, cases)
                    elseif length(args) === 1
                        make_match_body(args[1], arg_prefix, __module__, cases)
                    else
                        cases[1].body
                    end

                :($fn_name($(args...)) = $body)
            end
        end |>
        function (fns)
            Expr(:block, fns..., fn_name) |> esc
        end
    end

end


macro match(target, pattern_def)
    if !isa(pattern_def, Expr) || !(pattern_def.head in (:braces, :bracescat, :block))
        SyntaxError("Invalid leading marker of match body.") |> throw
    end

    mangling(target) do tag_sym
        cases = make_cases(pattern_def.args)
        make_match_body(target, tag_sym, __module__, cases) |> esc
    end
end

function pattern_match(expr :: Expr, guard, tag, mod :: Module)

    for (dispatcher_test, dispatch) in meta_dispatchers
        if dispatcher_test(expr)
            return dispatch(expr, guard, tag, mod)
        end
    end
    PatternUnsolvedException(expr) |> throw

end

function app_pattern_match(destructor, args, guard, tag, mod :: Module)
    global app_dispatchers
    fn =
        let destructor = get_most_union_all(destructor, mod)
                get(app_dispatchers, destructor, nothing)
        end

    if fn === nothing
        PatternUnsolvedException(:($destructor($(args...)))) |> throw
    else
        fn(args, guard, tag, mod)
    end

end

function register_meta_pattern(dispatch :: Function, dispatcher_test :: Function)
    global meta_dispatchers
    push!(meta_dispatchers, (dispatcher_test, dispatch));
end

function register_app_pattern(dispatch :: Function, destructor :: Any)
    global app_dispatchers
    push!(app_dispatchers, (destructor => dispatch))
end


# """
# builtin meta pattern(for application pattern)
# """
register_meta_pattern(expr :: Expr -> expr.head === :call) do expr, guard, tag, mod
    destructor = expr.args[1]
    app_pattern_match(destructor, expr.args[2:end], guard, tag, mod)
end

# """
# builtin application pattern(for dictionaries)
#
# x = "9"
# dict = Dict(1 => Dict(x => 3), 2 => 3)
#
# @match dict begin
#     Dict(1 => Dict(&x => a), 2 =>b) => a == b
# end
#
# # => true
#
# """
register_app_pattern(Dict) do args, guard, tag, mod

    matching =
        map(args) do kv
            if !(isa(kv, Expr) && kv.head === :call && (@eval mod $(kv.args[1])) === Pair)
                SyntaxError("Dictionary destruct must take patterns like Dict(<expr> => <pattern>)") |> throw
            end
            let (k, v) = kv.args[2:end]
                mangling(tag) do tag!
                    let tag! = Symbol(tag!, "[", k, "]"),
                        action = pattern_match(v, nothing, tag!, mod)

                        quote
                            $tag! = $get($tag, $k) do
                                    $failed
                            end
                            if $failed !== $tag!
                                $action
                            else
                                false
                            end
                        end
                    end
                end
            end
        end |>
        function (last)
            reduce((a, b) -> Expr(:&&, a, b), last, init=:($isa($tag, $Dict)))
        end

    check_ty = :($isa($tag, $Dict))

    if guard === nothing
        quote
            $check_ty && $matching
        end
    else
        quote
            $check_ty && $matching && $guard
        end
    end
end

register_app_pattern(in) do args, guard, tag, mod

    pattern, name = args

    let pat1 = pattern_match(pattern, nothing, tag, mod),
        pat2 = quote
                  $name = $tag
                  true
              end

        :($pat1 && $pat2) |>
        function (last)
            if guard === nothing
                last
            else
                :($last && $guard)
            end
        end
    end
end

module PatternDef
    import MLStyle.Match: register_app_pattern, register_meta_pattern

    App  = register_app_pattern
    Meta = register_meta_pattern
end

end # module
