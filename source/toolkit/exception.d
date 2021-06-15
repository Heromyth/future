module toolkit.exception;

import core.exception;
import std.exception;

mixin template BasicExceptionCtors() {
    this(size_t line = __LINE__, string file = __FILE__) @nogc @safe pure nothrow {
        super("", file, line, null);
    }

    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) @nogc @safe pure nothrow {
        super(msg, file, line, next);
    }

    this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__) @nogc @safe pure nothrow {
        super(msg, file, line, next);
    }

    this(Throwable next, string file = __FILE__, size_t line = __LINE__) @nogc @safe pure nothrow {
        assert(next !is null);
        super(next.msg, file, line, next);
    }

    // mixin basicExceptionCtors;
}

/* -------------------------------------------------------------------------- */
/*                                Basic exceptions                                 */
/* -------------------------------------------------------------------------- */

class CancellationException : Exception {
    mixin BasicExceptionCtors;
}

class NotImplementedException : Exception {
    mixin BasicExceptionCtors;
}

class NotSupportedException : Exception {
    mixin BasicExceptionCtors;
}

class IllegalArgumentException : Exception {
    mixin BasicExceptionCtors;
}

class TimeoutException : Exception {
    mixin BasicExceptionCtors;
}

/* -------------------------------------------------------------------------- */
/*                                IO exceptions                                */
/* -------------------------------------------------------------------------- */

class IOException : Exception {
    mixin BasicExceptionCtors;
}

class FileNotFoundException : IOException {
    mixin BasicExceptionCtors;
}


/* -------------------------------------------------------------------------- */
/*                                   Errors                                   */
/* -------------------------------------------------------------------------- */

class InternalError : Error {
    mixin BasicExceptionCtors;
}

class OutOfMemoryError : Error {
    mixin BasicExceptionCtors;
}