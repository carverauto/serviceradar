@0xe5fbb19e9e69110b;

struct Record {
    ts        @0 :Float64;
    hostname  @1 :Text;
    facility  @2 :UInt8;
    severity  @3 :UInt8;
    appname   @4 :Text;
    procid    @5 :Text;
    msgid     @6 :Text;
    msg       @7 :Text;
    fullMsg   @8 :Text;
    sdId      @9 :Text;
    pairs    @10 :List(Pair);
    extra    @11 :List(Pair);
}

struct Pair {
    key @0 :Text;
    value  :union {
        string @1 :Text;
        bool   @2 :Bool;
        f64    @3 :Float64;
        i64    @4 :Int64;
        u64    @5 :UInt64;
        null   @6 :Void;
    }
}
