module toolkit.meta;

import std.conv : text;
import std.range : iota;
import std.algorithm.iteration : joiner, map;
import std.traits;
import std.typecons;
import std.variant;

// https://forum.dlang.org/post/etbwyskitsyqjdhfebiu@forum.dlang.org
auto mapTuple(alias fn, T...)(Tuple!T arg) {
    return mixin(text("tuple(", T.length.iota.map!(i => text("fn(arg[", i,
            "])")).joiner(", "), ")"));
}

/* -------------------------------------------------------------------------- */
/*               Externded Algebraic visitor with Tuple support               */
/* -------------------------------------------------------------------------- */
template visitEx(Handlers...) if (Handlers.length > 0)
{
    ///
    auto visitEx(VariantType)(VariantType variant)
        if (isAlgebraic!VariantType)
    {
        return visitImpl!(true, VariantType, Handlers)(variant);
    }
}


template isAlgebraic(Type)
{
    static if (is(Type _ == VariantN!T, T...))
        enum isAlgebraic = T.length >= 2; // T[0] == maxDataSize, T[1..$] == AllowedTypesParam
    else
        enum isAlgebraic = false;
}


private auto visitImpl(bool Strict, VariantType, Handler...)(VariantType variant)
if (isAlgebraic!VariantType && Handler.length > 0)
{
    alias AllowedTypes = VariantType.AllowedTypes;


    /**
     * Returns: Struct where `indices`  is an array which
     * contains at the n-th position the index in Handler which takes the
     * n-th type of AllowedTypes. If an Handler doesn't match an
     * AllowedType, -1 is set. If a function in the delegates doesn't
     * have parameters, the field `exceptionFuncIdx` is set;
     * otherwise it's -1.
     */
    auto visitGetOverloadMap()
    {
        struct Result {
            int[AllowedTypes.length] indices;
            int exceptionFuncIdx = -1;
            int generalFuncIdx = -1;
            bool isExpanded = false; // for Tuple
        }

        Result result;

        foreach (tidx, T; AllowedTypes)
        {

            bool added = false;
            foreach (dgidx, dg; Handler)
            {
                // Handle normal function objects
                static if (isSomeFunction!dg)
                {
                    alias Params = Parameters!dg;
                            
                    // pragma(msg, "===========>");
                    // pragma(msg, "TTTTTT=>"~ T.stringof);
                    // pragma(msg, "dg=>"~ dg.stringof);
                    // pragma(msg, "Params=>"~ Params.stringof);

                    static if (Params.length == 0)
                    {
                        // Just check exception functions in the first
                        // inner iteration (over delegates)
                        if (tidx > 0)
                            continue;
                        else
                        {
                            if (result.exceptionFuncIdx != -1)
                                assert(false, "duplicate parameter-less (error-)function specified");
                            result.exceptionFuncIdx = dgidx;
                        }
                    }
                    else static if (Params.length == 1 && (is(Params[0] == T) || is(Unqual!(Params[0]) == T)))
                    {
                        if (added)
                            assert(false, "duplicate overload specified for type '" ~ T.stringof ~ "'");

                        added = true;
                        result.indices[tidx] = dgidx;
                    } else static if(Params.length > 1 && isTuple!T) {

                        static if(is(T.Types == Params)) {
                            if (added)
                                assert(false, "duplicate overload specified for type '" ~ T.stringof ~ "'");

                            added = true;
                            result.indices[tidx] = dgidx;
                            result.isExpanded = true;
                        } else {
                            pragma(msg, "skipped dg: "~ dg.stringof ~ " params: " ~Params.stringof);
                        }
                    }
                }
                else static if (isSomeFunction!(dg!T))
                {
                    assert(result.generalFuncIdx == -1 ||
                           result.generalFuncIdx == dgidx,
                           "Only one generic visitor function is allowed");
                    result.generalFuncIdx = dgidx;
                }
                // Handle composite visitors with opCall overloads
                else
                {
                    static assert(false, dg.stringof ~ " is not a function or delegate");
                }
            }

            if (!added)
                result.indices[tidx] = -1;
        }

        return result;
    }

    enum HandlerOverloadMap = visitGetOverloadMap();

    if (!variant.hasValue)
    {
        // Call the exception function. The HandlerOverloadMap
        // will have its exceptionFuncIdx field set to value != -1 if an
        // exception function has been specified; otherwise we just through an exception.
        static if (HandlerOverloadMap.exceptionFuncIdx != -1)
            return Handler[ HandlerOverloadMap.exceptionFuncIdx ]();
        else
            throw new VariantException("variant must hold a value before being visited.");
    }

    foreach (idx, T; AllowedTypes)
    {
        if (auto ptr = variant.peek!T)
        {
            enum dgIdx = HandlerOverloadMap.indices[idx];

            static if (dgIdx == -1)
            {
                static if (HandlerOverloadMap.generalFuncIdx >= 0)
                    return Handler[HandlerOverloadMap.generalFuncIdx](*ptr);
                else static if (Strict)
                    static assert(false, "overload for type '" ~ T.stringof ~ "' hasn't been specified");
                else static if (HandlerOverloadMap.exceptionFuncIdx != -1)
                    return Handler[HandlerOverloadMap.exceptionFuncIdx]();
                else
                    throw new VariantException(
                        "variant holds value of type '"
                        ~ T.stringof ~
                        "' but no visitor has been provided"
                    );
            }
            else
            { 
                static if(isTuple!T && HandlerOverloadMap.isExpanded) {
                    return Handler[ dgIdx ]((*ptr).expand);
                } else {
                    return Handler[ dgIdx ](*ptr);
                }
            }
        }
    }

    assert(false);
}



import std.typecons;

/*
	Transform symbols into a form usable within `universal`.

	The reason that symbols need to be normalized is because D functions don't compose.
		example 1: `void f(){}`: there is no symbol `g` for which either `g(f())` or `f(g())` exists.
		example 2: `auto f(A a, B b)` : there is no symbol `g` for which `f(g())` exists.

	To work around these inconsistencies, the following assumptions are made by the internals of `universal`:
		1) All functions return some value.
		2) Any `tuple(a,b,c)` is alpha-equivalent to its expansion `a,b,c` if it is passed as the first argument to a function.

	Assumption (2) allows us to emulate multiple return values, solving example 2.
	Both assumptions together solve example 1. In fact, `f` itself satisfies `g`.
		
	To support these assumptions, a function `f` is normalized by being lifted through `apply` as a template argument.
	If `f` returns `void`, `apply!f` calls `f` and returns the empty `Tuple!()`, aka `Unit`.
	`apply!f` may transform its arguments before passing them to `f`, either by expanding the first argument into multiple arguments (if it is a tuple) or by packing multiple arguments into a tuple. Preference is given to passing the arguments through untouched.

	As a coincidental convenience, `apply` can be useful for performing a function on a range in a UFCS chain, in which some range-level information is needed (like `$` does for `.length` in the context of `opIndex`).
*/
template apply(alias f, string file = __FILE__, size_t line = __LINE__)
{
  template apply(A...)
  {
		static if(is(typeof(f(A.init)) == B, B))
			enum pass;
		else static if(is(typeof(f(A.init[0][], A.init[1..$])) == B, B))
			enum expand;
		else static if(is(typeof(f(A.init.tuple)) == B, B))
			enum enclose;
		else 
		{
			// pragma(msg, typeof(f(A.init)));

			alias B = void;

			static assert(0,
				"couldn't apply "~__traits(identifier, f)~A.stringof
			);
		}

		static if(is(B == void))
			alias C = Tuple!();
		else
			alias C = B;

		C apply(A a)
		{
			auto applied()
			{
				static if(is(pass))
				{ return f(a); }
				else static if(is(expand))
				{ return f(a[0][], a[1..$]); }
				else static if(is(enclose))
				{ return f(tuple(a)); }
			}

			static if(is(typeof(applied()) == void))
			{ applied; return tuple; }
			else
			{ return applied; }
		}
  }
}