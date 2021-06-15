module toolkit.promise;

import toolkit.exception;
import toolkit.logging;
import toolkit.meta;

import core.atomic;
import core.sync.condition;
import core.sync.mutex;
import core.time;
import core.thread;

import std.algorithm;
import std.concurrency;
import std.datetime;
import std.parallelism;
import std.meta : allSatisfy;
import std.range : only;
import std.typecons : tuple, Tuple, isTuple;
import std.traits;
import std.variant;

/**
 * Event handler for a promise
 */
template PromiseHandler(T) {
    static if(is(T == void)) {
        alias PromiseHandler = void delegate();
    } else {
        alias PromiseHandler = void delegate(T v);
    }
}

/**
 * 
 */
enum isPromise(F) = is(F == Promise!A, A);


/**
*/
interface IPromise {

    bool isPending();

    bool isCancelling();

    bool isCancelled();

    bool isFailed();

    bool isSucceeded();

    bool isDone();
}

abstract class PromiseBase : IPromise {
    protected PromiseBase onCompleted(void delegate() handler);

}


/**
 * See_also:
 * https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Promise
 */
class Promise(R) : PromiseBase if (!is(R : Throwable)) {
    alias ResultType = R;

    enum State {
        Pending,
        Cancelling,
        Fulfilled,
        Rejected
    }

    protected PromiseHandler!(void)[] _completedHandlers;
    protected Throwable _cause;
    protected shared State _state;

    this() {
        _state = State.Pending;
    }

    this(Throwable e) {
        _cause = e;
        _state = State.Rejected;
    }

    static if (!is(R == void)) {
        this(R value) {
            this._result = value;
            _state = State.Fulfilled;
        }

        protected R _result;
    }

    bool isPending() {
        return _state == State.Pending;
    }

    bool isCancelling() {
        return _state == State.Cancelling;
    }

    bool isCancelled() {
        CancellationException e = cast(CancellationException) _cause;
        return e !is null;
    }

    bool isFailed() {
        return _cause !is null; //  _state == State.Rejected;
    }

    bool isSucceeded() {
        return _state == State.Fulfilled;
    }

    bool isDone() {
        return _state == State.Fulfilled || _state == State.Rejected;
    }

    /**
     * To get the result in thread way.
     */
    R get() {
        
        while (!isDone()) {
            Thread.yield();
        }

        version(Toolkit_Debug) trace("return now: ", isDone());

        if(!isSucceeded()) {
            throw _cause;
        }
        static if (!is(R == void)) {
            return _result;
        }
    }

    /**
     * An invalid result will be returned if timeout.
     */
    R get(Duration timeout) {
        version(Toolkit_Debug) tracef("getting result...");

        if (!isDone()) {
            auto start = Clock.currTime;
            while (!isDone() && Clock.currTime < start + timeout) {
                Thread.yield();
            }
            
            if (!isDone()) {
                // It's better to throw a exception when timeout.
                throw new TimeoutException("The promise has not fulfilled!");
            }
        }

        version(Toolkit_Debug) trace("return now: ", isDone());
        static if (!is(R == void)) {
            return _result;
        }
    }

    Promise!R cancel(bool immediately = false) {
        if (cas(&_state, State.Pending, State.Cancelling)) {
            if (immediately) {
                return reject(new CancellationException());
            } else {
                return this;
            }
        } else if (isDone()) {
            throw new Exception("Can't cancel a finished promise.");
        }

        return this;
    }

    protected void onCompleted() {
            
        foreach (PromiseHandler!void handler; _completedHandlers) {
            handler();
        }
        _completedHandlers = [];

    }

static if(is(R == void)) {
    Promise!R resolve() { // succeeded
        if (cas(&_state, State.Pending, State.Fulfilled)) {
            version(Toolkit_Debug) trace("result: void");
            onCompleted();
        }

        return this;
    }

    private void run(F, Args...)(F fn, Args args) {
        try {
            version(Toolkit_Debug) trace("running a promise...");
            fn(args);
            resolve();
        } catch (Throwable t) {
            reject(t);
        }
    }

} else {

    Promise!R resolve(R a) { // succeeded
        if (cas(&_state, State.Pending, State.Fulfilled)) {
            _result = a;
            version(Toolkit_Debug) tracef("result: %s", a);
            onCompleted();
        }

        return this;
    }

    private void run(F, Args...)(F fn, Args args) {
        try {
            version(Toolkit_Debug) trace("running a promise...");
            R r = fn(args);
            resolve(r);
        } catch (Throwable t) {
            reject(t);
        }
    }     
}

    override protected Promise!R onCompleted(PromiseHandler!void handler) {
        synchronized (this) {
            if (isDone()) // REVIEW could this lead to deadlock? can that be analyzed with π calculus?
                handler();
            else
                this._completedHandlers ~= handler;
        }

        return this;
    }   


    Promise!R reject(Throwable e) {
        assert(e !is null);
        if (cas(&_state, State.Pending, State.Rejected) || 
            cas(&_state, State.Cancelling, State.Rejected)) {
            this._cause = e;
            version(Toolkit_Debug) warningf("exception: %s", e.msg);
            version(Toolkit_Debug_More) warningf("exception: %s", e);
            onCompleted();
        }
        return this;
    }
}

/**
 * 
 */
class MultexPromise(R) : Promise!R {
    // https://stackoverflow.com/questions/26798073/difference-between-wait-and-yield
    // https://stackoverflow.com/questions/8594591/why-does-pthread-cond-wait-have-spurious-wakeups
    // https://stackoverflow.com/questions/41272325/about-the-usage-of-pthread-cond-wait
    // https://stackoverflow.com/questions/56056711/threadyield-vs-threadonspinwait?noredirect=1
    // https://stackoverflow.com/questions/5869825/when-should-one-use-a-spinlock-instead-of-mutex
    // https://shlomisteinberg.com/2018/06/24/fast-shared-upgradeable-mutex/
    // https://mortoray.com/2019/02/20/how-does-a-mutex-work-what-does-it-cost/
    // https://www.codeproject.com/Articles/1183423/We-make-a-std-shared-mutex-times-faster

	private Mutex _doneLocker;
	private Condition _doneCondition;

    this() {
        super();
		_doneLocker = new Mutex();
		_doneCondition = new Condition(_doneLocker);
    }

    override void onCompleted() {
        _doneCondition.notifyAll();
        super.onCompleted();
    }

    override R get() {
        version(Toolkit_Debug) tracef("getting result..." );
        if(!isDone) {
            _doneLocker.lock();
            scope (exit)
                _doneLocker.unlock();
            version (Toolkit_Debug)
                info("Waiting for a promise...");
            _doneCondition.wait();
        }

        version(Toolkit_Debug) trace("return now: ", isDone());

        if(!isSucceeded()) {
            throw _cause;
        }
        static if (!is(R == void)) {
            return _result;
        }
    } 

    override R get(Duration timeout) {
        
        if (!isDone()) {
			_doneLocker.lock();
			scope (exit)
				_doneLocker.unlock();

			version (Toolkit_Debug)
				infof("Waiting for a promise in %s...", timeout);
			if (!_doneCondition.wait(timeout))
				throw new TimeoutException("The promise has not fulfilled!");
        }

        version(Toolkit_Debug) trace("return now: ", isDone());
        static if (!is(R == void)) {
            return _result;
        }
    }
}

/**
 * 
 */
// class ThieldPromise(R) : Promise!R {
    
//     this() {
//         super();
//     }

//     override R get() {
//         version(Toolkit_Debug) tracef("getting result..." );

//         while (!isDone()) {
//             Thread.yield();
//         }
        
//         static if(is(R == void)) {
//             super.get();
//         } else {
//             return super.get();
//         }
//     }

    
//     R get(Duration timeout) {
        
//         if (!isDone()) {
//             auto start = Clock.currTime;
//             while (!isDone() && Clock.currTime < start + timeout) {
//                 Thread.yield();
//             }
            
//             if (!isDone()) {
//                 // It's better to throw a exception when timeout.
//                 throw new TimeoutException("The promise has not fulfilled!");
//             }
//         }

//         static if(is(R == void)) {
//             super.get();
//         } else {
//             return super.get();
//         }
//     }

// }

/* -------------------------------------------------------------------------- */
/*                           Opertors for a promises                          */
/* -------------------------------------------------------------------------- */

/* -------------------------------- Constructors -------------------------------- */

/**
 * create a empty pending promise
 */
Promise!A promise(A)() {
    return new Promise!A();
}

/**
 * It always create a promise with a action, and excute the action in another thread.
 */
template promise(F, Args...) {
    alias R = ReturnType!F;

    Promise!(R) promise(F fn, Args args) {
        auto p = new MultexPromise!(R)();
        
        auto futureTask = task(&(p.run!(F, Args)), fn, args);
        taskPool.put(futureTask);

        return p;
    }
}

/* ------------------------------ async / await ----------------------------- */

/**
 * Binding an action with a promise in a fiber. 
 * 
 */
template async(alias fn) 
    if(isSomeFunction!fn) {

    template async(Args...) {
        alias R = ReturnType!fn;

        Promise!R async(Args args) {
            return asyncImpl(fn, args);
        }
    }
}

/// ditto
template async(F, Args...) 
    if(isSomeFunction!F) {
    alias R = ReturnType!F;

    Promise!(R) async(F fn, Args args) {
        return asyncImpl(fn, args);
    }
}

private template asyncImpl(F, Args...) {
    alias R = ReturnType!F;

    Promise!(R) asyncImpl(F fn, Args args) {
        auto p = promise!R();
        // It seems that the Fiber is the right way.
        // https://github.com/dotnet/corefxlab/issues/2168

        static if(!is(R == void)) R value;
        
        auto gen = new Generator!PromiseBase(() {
            version(Toolkit_Debug) infof("executing a async action... %s", fn is null);
            try {
                static if(is(R == void)) {
                    fn(args);
                } else {
                    value = fn(args);
                }
            } catch(Exception ex) {
                version(Toolkit_Debug) warning(ex.msg);
                version(Toolkit_Debug_More) warning(ex);
                p.reject(ex);
            } catch(Throwable t) {
                warning(t.msg);
            }
        }); 

        void step() {
            if(gen.empty()) {
                static if(is(R == void)) {
                    p.resolve();
                }else {
                    p.resolve(value);
                }
            } else {
                gen.front.onCompleted(() {
                    version(Toolkit_Debug) info("starting next step...");
                    gen.popFront();
                    
                    step();
                });
            }
        }

        version(Toolkit_Debug) info("starting one step...");
        step();
        version(Toolkit_Debug) info("ended one step.");            

        return p;
    }
}


/**
 * 
 * See_Also:
 *    https://shlomisteinberg.com/2018/06/24/fast-shared-upgradeable-mutex/
 *    https://www.codeproject.com/Articles/1183423/We-make-a-std-shared-mutex-times-faster
 *    https://mortoray.com/2019/02/20/how-does-a-mutex-work-what-does-it-cost/
 */
template await(A) {
    
    /**
     * Await a promise, and return it's result.
     * 
     * It will auto detect the aync mode: thread or fiber.
     */
    A await(Promise!A p) {

        auto thisFiber = cast(Generator!PromiseBase)Fiber.getThis;
        version(Toolkit_Debug_More) infof("%s, using fiber: %s", typeid(p),  thisFiber !is null);

        if(thisFiber !is null) {
            yield!(PromiseBase)(p);
        }

        return p.get();
    }

    /**
     * Await a promise, and return it's result.
     * 
     * It will auto detect the aync mode: thread or fiber.
     * 
     * Warnings:
     *   The timeout is no useful for a fiber.
     */
    A await(Promise!A p, Duration timeout) {
        auto thisFiber = cast(Generator!PromiseBase)Fiber.getThis;
        version(Toolkit_Debug) infof("%s, a fiber: %s", typeid(p),  thisFiber !is null);

        if(thisFiber !is null) {
             yield!(PromiseBase)(p);
        }

        return p.get(timeout);
    }
}

/* ---------------------------------- then ---------------------------------- */

/**
 * 
 */
template then(alias fn) if(isSomeFunction!fn) {
    template then(A, B...) {
        alias R = ReturnType!(fn);
        Promise!R then(Promise!A p, B args) {
            return .then(p, fn, args);
        }
    }
}

template isTemplateFunction(alias fn) {
    static if(is(fn : T!Args, T, Args...)) {
        enum isTemplateFunction = true;
    } else {
        enum isTemplateFunction = false;
    }
}

/**
 * 
 * Parameters:
 *   fn is a template, and its first parameter is a function or delegate
 * 
 * See_also:
 *   https://forum.dlang.org/post/kxlmndgvuzxkpnqghicf@forum.dlang.org
 *   https://forum.dlang.org/post/cpmgkfmfxaoarrecqdvv@forum.dlang.org
 */
template then(alias fn : T!(fun, Args), alias T, alias fun, Args... ) 
        if(isSomeFunction!(fun)) {

    template then(A, B...)  {
        alias C = ReturnType!(fun);
    
        Promise!C then(Promise!A p, B args) {
            auto r = promise!C();
            p.onCompleted(() {
                if(p.isSucceeded()) { 
                    auto s = fn(p._result, args); 
                    s.onCompleted(() { 
                        if(s.isSucceeded()) { r.resolve(s._result); }
                        else r.reject(s._cause);
                    });
                } else {
                    r.reject(p._cause);
                }
            });
            return r;
        }
    }
}

/**
 * 
 */
template then(F, A, B...) if(isSomeFunction!F) {
    alias C = ReturnType!F;

    Promise!C then(Promise!A p, F fn, B args) {
        auto r = promise!C();
        p.onCompleted(() {
            if(p.isSucceeded()) { 
                r.run(fn, p._result, args); 
            } else {
                r.reject(p._cause);
            }
        });

        return r;
    }
}

/**
 * 
 */
template then(F, A, B...) if(isPromise!F) {
    alias C = F.ResultType;

    Promise!C then(Promise!A p, F fn, B args) {
        auto r = promise!C();
        p.onCompleted(() {
            if(p.isSucceeded()) { 
                r.resolve(fn(p._result, args));
            } else {
                r.reject(p._cause);
            }
        });

        return r;
    }
}

/**
 * Deduce a chained promise.
 * 
 * Return a new promise with its type same as the inner promise's.
 */
Promise!A deduce(A)(Promise!(Promise!A) p) {
    auto r = promise!A();
    p.onCompleted(() {
        if(p.isSucceeded()) { 
            auto s = p._result;
            s.onCompleted(() { 
                if(s.isSucceeded()) {
                    r.resolve(s._result);
                } else {
                    r.reject(s._cause);
                }  
            });
        } else {
            r.reject(p._cause);
        } 
    });
    return r;
}

/**
 * 
 */
template thenAsync(alias fn, A, Args...) if(isSomeFunction!fn) {
    alias C = ReturnType!fn;

    Promise!C thenAsync(Promise!A p, Args args) {
        return thenAsync(p, fn, args);
    }
}

/// ditto
template thenAsync(F, A, Args...) if(isSomeFunction!F) {
    alias C = ReturnType!F;

    Promise!C thenAsync(Promise!A p, F fn, Args args) {
        auto r = promise!C();
        p.onCompleted(() {
            if(p.isSucceeded()) {
                auto futureTask = task(&(r.run!(typeof(fn), A, Args)), fn, p._result, args);
                taskPool.put(futureTask);
            } else {
                r.reject(p._cause);
            } 
        });
        return r;
    }
}

/* ---------------------------------- when ---------------------------------- */

/**
 * when: maps a tuple of futures to a future tuple completes when all complete
 * 
 * when(a,b) is a future Tuple(a.result, b.result), ready when both a and b are ready
 */
private template whenImpl(W, A) if (isTuple!A && allSatisfy!(isPromise, A.Types)) {

    Promise!W whenImpl(A futures) {
        Promise!W allFuture = promise!W;
        foreach (i, p; futures) {
            p.onCompleted(() {
                synchronized (allFuture) { // keep thread-safe here
                    if (all!(a => a.isDone())(futures.expand.only)) {
                        try {
                            W r = mapTuple!((p) {
                                    if(p.isSucceeded()) return p._result;
                                    else { throw p._cause; }
                                })(futures);

                            allFuture.resolve(r);
                        } catch(Exception ex) {
                            version(Toolkit_Debug) warning(ex.msg);
                            version(Toolkit_Debug_More) warning(ex);
                            allFuture.reject(ex);
                        }
                    }
                }
            });            
        }

        return allFuture;
    }
}

/**
 * 
 * See_also:
 *   https://stackoverflow.com/questions/30362733/handling-errors-in-promise-all
 *   https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Promise/all
 */
template when(Args...) if (allSatisfy!(isPromise, Args)) {
    alias getResultType(F) = F.ResultType;
    alias W = Tuple!(staticMap!(getResultType, Args));
    
    Promise!W when(Args args) {
        return whenImpl!(W)(args.tuple);
    }
}

/* ---------------------------------- race ---------------------------------- */

private template raceImpl(A) if (isTuple!A && allSatisfy!(isPromise, A.Types)) {
    alias getResultType(F) = F.ResultType;
    alias R = Algebraic!(staticMap!(getResultType, A.Types));
    alias RaceTypes = R.AllowedTypes;

    Promise!R raceImpl(A futures) {
        auto anyFuture = promise!R;

        foreach (i, p; futures) {
            version(Toolkit_Debug) trace(RaceTypes[i].stringof);

            // p.onFulfill((RaceTypes[i] result) {
            //     anyFuture.resolve(R(result));
            // });
            p.onCompleted(() {
                if(p.isSucceeded()) {
                    anyFuture.resolve(R(p._result));
                } else {
                    anyFuture.reject(p._cause);
                }
            });
        }

        return anyFuture;
    }
}

template race(Args...) if (allSatisfy!(isPromise, Args)) {
    auto race(Args args) {
        return raceImpl(args.tuple);
    }
}

/* -------------------------------------------------------------------------- */
/*                                    Utils                                   */
/* -------------------------------------------------------------------------- */

/**
 * Create a promise for timeout in another thread.
 * 
 * See_also:
 *     https://stackoverflow.com/questions/4238345/asynchronously-wait-for-taskt-to-complete-with-timeout
 */
Promise!void delayAsync(Duration timeout) {
    Promise!void p;
    p = promise(() { 
        version(Toolkit_Debug) trace("Sleeping...");
        Thread.sleep(timeout); 
        version(Toolkit_Debug) trace("Wake up now.");
    });

    return p;
}
