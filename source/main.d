
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
    int factor = 2;
    auto ex2a = new Promise!int();

    auto ex2b = ex2a.then!(async!((int x) { 
            if(x == 30) {
                // It's a bug in macOS Big Sur 11.4
                throw new Exception("throw an exception!");
            }
            return x * factor; 
        }));    

    ex2a.resolve(30); // throw an exception!
}

