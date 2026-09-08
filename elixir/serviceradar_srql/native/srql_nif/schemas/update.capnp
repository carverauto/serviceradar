@0x83f9299a125b7932;

struct Update {
    timeReceivedNs      @0  :UInt64;
    timeBmpHeaderNs     @1  :UInt64;
    routerAddr          @2  :Data;
    routerPort          @3  :UInt16;
    peerAddr            @4  :Data;
    peerBgpId           @5  :UInt32;
    peerAsn             @6  :UInt32;
    prefixAddr          @7  :Data;
    prefixLen           @8  :UInt8;
    isPostPolicy        @9  :Bool;
    isAdjRibOut         @10 :Bool;
    announced           @11 :Bool;
    synthetic           @12 :Bool;

    origin              @13 :Text;
    asPath              @14 :List(UInt32);
    nextHop             @15 :Data;
    multiExitDisc       @16 :UInt32;
    localPreference     @17 :UInt32;
    onlyToCustomer      @18 :UInt32;
    atomicAggregate     @19 :Bool;
    aggregatorAsn       @20 :UInt32;
    aggregatorBgpId     @21 :UInt32;
    communities         @22 :List(Community);
    extendedCommunities @23 :List(ExtendedCommunity);
    largeCommunities    @24 :List(LargeCommunity);
    originatorId        @25 :UInt32;
    clusterList         @26 :List(UInt32);
    mpReachAfi          @27 :UInt16;
    mpReachSafi         @28 :UInt8;
    mpUnreachAfi        @29 :UInt16;
    mpUnreachSafi       @30 :UInt8;
}

struct Community {
    asn                 @0  :UInt32;
    value               @1  :UInt16;
}

struct ExtendedCommunity {
    typeHigh            @0  :UInt8;
    typeLow             @1  :UInt8;
    value               @2  :Data;
}

struct LargeCommunity {
    globalAdmin         @0  :UInt32;
    localDataPart1      @1  :UInt32;
    localDataPart2      @2  :UInt32;
}
