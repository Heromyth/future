
import toolkit.exception;
import toolkit.promise;
import toolkit.logging;
import toolkit.meta;

import core.thread;
import std.typecons;
import std.conv;
import std.variant;
import std.concurrency;
import std.meta;

void main() {
    trace("main thread");

    // test01();

    // test02();
    test02_01();
    // test02_02();

    // test03();
    // test04();

    // test05_01();
    // test05_02();
    // test05_03();

    // test06();

    // bug test
    // import std.conv;
    // // enum int i = staticIndexOf!(  int, byte, short, int, long);
    // enum i = staticIndexOf!(  int, byte, short, int, long);
    // pragma(msg, "i=" ~ i.to!string());
    // static assert(i > -1, "must >= 0. actual: " ~ i.to!string());

    // testApply();
}


// void testApply() {
//     // import  universal.core.apply;
//     import toolkit.meta;
//     static int add(int a, int b) { return a + b; }
// 	assert(apply!add(tuple(1,2)) == apply!add(1,2));

// 	static void f() {}
// 	assert(apply!f == tuple);

// 	assert( !__traits(compiles, f(f)));
// 	assert(__traits(compiles, apply!f(apply!f)));
// }

/*
    basic usage
*/
void test01() {
    auto ex1 = new Promise!int();
    assert(ex1.isPending);
    ex1.resolve(6);
    assert(ex1.isDone);
    assert(ex1.get() == 6);
}

/*
    then: mapping over futures
*/
void test02() {
    auto ex2a = new Promise!int();
    int factor = 2;
    auto ex2b = ex2a.then!((int x) => x * factor)();
    auto ex2c = ex2a.then((int x) => x * factor);
    
    assert(ex2a.isPending && ex2b.isPending);
    assert(ex2c.isPending);

    ex2a.resolve(3);
    assert(ex2a.isDone && ex2b.isDone);
    assert(ex2b.get() == 6);

    assert(ex2c.isDone);
    assert(ex2c.get() == 6);
}

void test02_01() {
    int factor = 2;
    auto ex2a = new Promise!int();

    auto ex2b = ex2a.then!(async!((int x) { 
            info("running here");
            if(x == 30)
                throw new Exception("throw an exception!");
            return x * factor; 
        }));    

    auto ex2c = ex2a.then!(async!((int x) { 
            info("running here");
            try {
                if(x == 3) {
                    warning("try to throw an exception");
                    // It's a bug in macOS Big Sur 11.4
                    throw new Exception("throw a exception!");
                }
            } catch(Exception x) {
                warningf("Here is an exception! %s", x.msg);
            }
            return x * factor; 
        }));  

    
    // auto ex2d = ex2a.then(async!((int x) { 
    //         info("running here");
    //         return x * factor; 
    //     }));    // TODO: 

    assert(ex2a.isPending && ex2b.isPending);
    assert(ex2c.isPending);

    ex2a.resolve(3); // throw a exception!

    // assert(ex2a.isDone && ex2b.isDone);

    // try {
    //     assert(ex2b.get() == 6);
    // } catch (Exception ex) {
    //     warning(ex.msg);
    // }

    // // assert(ex2c.isDone);   // Can't assert the ex2c is done here.
    // try {
    //     assert(ex2c.get() == 6);
    // } catch (Exception ex) {
    //     warning(ex.msg);
    // }
    // assert(ex2c.isDone);
}

void test02_02() {
    auto ex2a = new Promise!int();
    int factor = 2;
    auto ex2b = ex2a.thenAsync!((int x) => x * factor)();
    auto ex2c = ex2a.thenAsync((int x) => x * factor);
    
    assert(ex2a.isPending && ex2b.isPending);
    ex2a.resolve(3);
    assert(ex2a.isDone);
    assert(ex2b.get() == 6);
}


/*
    when: maps a tuple of futures to a future tuple 
        completes when all complete
*/
void test03() {
    auto ex3a = promise!int;
    auto ex3b = promise!int;
    auto ex3c = promise!int;
    auto ex3 = when(ex3a, ex3b, ex3c);
    assert(ex3.isPending);
    ex3a.resolve(1);
    ex3b.resolve(2);
    assert(ex3.isPending);
    ex3c.resolve(3);
    assert(ex3.isDone());
    assert(ex3.get() == tuple(1, 2, 3));
}

/*
    race: maps a tuple of futures to a future union
        inhabited by the first of the futures to complete
*/
void test04() {
    auto ex4a = promise!int;
    auto ex4b = promise!(Tuple!(int, int));
    auto ex4 = race(ex4a, ex4b);
    assert(ex4.isPending);
    ex4b.resolve(tuple(1, 2));
    assert(ex4.isDone());
    auto result = ex4.get();  // Algebraic
    // assert(result.visit2!((int x) => x, (x, y) => x + y) == 3);
    // assert(ex4.result.visit!((x) => x, (x, y) => x + y) == 3);
    assert(result.visitEx!((int x) => x, (Tuple!(int, int) t) => t[0] + t[1]) == 3);
    assert(result.visitEx!((int x) => x, (int x, int y) => x + y) == 3);
}

/*
    async/await: multithreaded function calls
*/
void test05_01() {
    auto ex5a = tuple(3, 2)[].async!((int x, int y) {
        trace("waiting here: ", x);
        // Thread.sleep(5000.msecs);

        // Promise!int p = delayAsync(5.seconds);
        // yield!(PromiseBase)(p);
        Promise!void p = delayAsync(5.seconds);
        await(p);

        trace("running here: ");
        return to!string(x * y);
    });

    trace("ex5a isPending: ", ex5a.isPending); // true
    try {
        auto r = await(ex5a, 200.msecs);
    } catch(TimeoutException ex) {
        info(ex.msg);
        trace("ex5a isPending: ", ex5a.isPending); // true, and a invalid result will be returned
    } catch(Exception ex) {
        warning("unhandled exception: ", ex);
    }
    
    trace("ex5a isPending: ", ex5a.isPending); // true, and a invalid result will be returned
    // BUG: Reported defects -@putao at 2019-09-22T00:35:38.389Z
    // It can't work with ldc2.
    auto r = await(ex5a); // wait for a result
    tracef("r=%s", r);
}

Promise!void delayAsyncWithException(Duration timeout) {
    Promise!void p = promise(() { 
        version(Tookit_Debug) trace("Sleeping...");
        Thread.sleep(timeout); 
        version(Tookit_Debug) trace("Wake up now.");

        throw new Exception("thrown an exception");
    });

    return p;
}

void test05_02() {
    auto ex5a = tuple(3, 2)[].async!((int x, int y) {
        trace("waiting here: ", x);

        // Promise!void p = delayAsyncWithException(5.seconds);
        Promise!void p = delayAsync(5.seconds);
        await(p);

        warning("running here: ");
        if (x == 32)
            throw new Exception("throwing an exception");
        return to!string(x * y);
    });

    trace("ex5a isPending: ", ex5a.isPending); // true
    try {
        auto r = await(ex5a, 200.msecs);
    } catch(TimeoutException ex) {
        info(ex.msg);
        trace("ex5a isPending: ", ex5a.isPending); // true, and a invalid result will be returned
    } catch(Exception ex) {
        warning("unhandled exception: ", ex);
    }
    
    trace("ex5a isPending: ", ex5a.isPending); // true, and a invalid result will be returned

    try {
        auto r = await(ex5a); // wait for a result
        tracef("r=%s", r);
    } catch(Exception ex) {
        infof("isdone: %s", ex5a.isDone()); // dcd bug 
        warning(ex.msg);
    }
}

void test05_03() {

    auto ex5a = tuple(3, 2)[].async!((int x, int y) {
        trace("waiting here: ", x);
        // Thread.sleep(5000.msecs);

        // Promise!int p = delayAsync(5.seconds);
        // yield!(PromiseBase)(p);
        Promise!void p = delayAsync(5.seconds);
        await(p);

        // p = delayAsync(2.seconds);
        // await(p);

        trace("running here: ");
        return to!string(x * y);
    });

    trace("ex5a isPending: ", ex5a.isPending); // true

    auto r = await(ex5a);

    info("r: ", r);
}

void test06() {
    int factor = 2;
    auto ex7a = async((int i) => to!string(i*factor), 12); 
    auto ex7b = async!((int i) => to!string(i*factor))(12);
    
    assert(ex7b.isDone() && ex7a.isDone());
    assert(ex7a.get() == "24");
}