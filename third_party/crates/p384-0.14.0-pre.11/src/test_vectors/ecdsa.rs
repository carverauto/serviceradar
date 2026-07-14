//! ECDSA/secp384r1 test vectors

use ecdsa_core::dev::TestVector;
use hex_literal::hex;

/// ECDSA/P-384 test vectors.
///
/// Adapted from the FIPS 186-4 ECDSA test vectors
/// (P-384, SHA-384, from `SigGen.txt` in `186-4ecdsatestvectors.zip`)
/// <https://csrc.nist.gov/projects/cryptographic-algorithm-validation-program/digital-signatures>
///
/// The `m` field contains a SHA-384 prehash of the `Msg` field in the
/// original `SigTen.txt`.
pub const ECDSA_TEST_VECTORS: &[TestVector; 15] = &[
    TestVector {
        d: &hex!(
            "201b432d8df14324182d6261db3e4b3f46a8284482d52e370da41e6cbdf45ec2952f5db7ccbce3bc29449f4fb080ac97"
        ),
        q_x: &hex!(
            "c2b47944fb5de342d03285880177ca5f7d0f2fcad7678cce4229d6e1932fcac11bfc3c3e97d942a3c56bf34123013dbf"
        ),
        q_y: &hex!(
            "37257906a8223866eda0743c519616a76a758ae58aee81c5fd35fbf3a855b7754a36d4a0672df95d6c44a81cf7620c2d"
        ),
        k: &hex!(
            "dcedabf85978e090f733c6e16646fa34df9ded6e5ce28c6676a00f58a25283db8885e16ce5bf97f917c81e1f25c9c771"
        ),
        m: &hex!(
            "31a452d6164d904bb5724c878280231eae705c29ce9d4bc7d58e020e1085f17eebcc1a38f0ed0bf2b344d81fbd896825"
        ),
        r: &hex!(
            "50835a9251bad008106177ef004b091a1e4235cd0da84fff54542b0ed755c1d6f251609d14ecf18f9e1ddfe69b946e32"
        ),
        s: &hex!(
            "0475f3d30c6463b646e8d3bf2455830314611cbde404be518b14464fdb195fdcc92eb222e61f426a4a592c00a6a89721"
        ),
    },
    TestVector {
        d: &hex!(
            "23d9f4ea6d87b7d6163d64256e3449255db14786401a51daa7847161bf56d494325ad2ac8ba928394e01061d882c3528"
        ),
        q_x: &hex!(
            "5d42d6301c54a438f65970bae2a098cbc567e98840006e356221966c86d82e8eca515bca850eaa3cd41f175f03a0cbfd"
        ),
        q_y: &hex!(
            "4aef5a0ceece95d382bd70ab5ce1cb77408bae42b51a08816d5e5e1d3da8c18fcc95564a752730b0aabea983ccea4e2e"
        ),
        k: &hex!(
            "67ba379366049008593eac124f59ab017358892ee0c063d38f3758bb849fd25d867c3561563cac1532a323b228dc0890"
        ),
        m: &hex!(
            "a92784916a40feaebfeab16ea28c0c65e45c5e81eb634052944865708072e20110bd669a9838d7e722e94ac75245cdd3"
        ),
        r: &hex!(
            "fb318f4cb1276282bb43f733a7fb7c567ce94f4d02924fc758635ab2d1107108bf159b85db080cdc3b30fbb5400016f3"
        ),
        s: &hex!(
            "588e3d7af5da03eae255ecb1813100d95edc243476b724b22db8e85377660d7645ddc1c2c2ee4eaea8b683dbe22f86ca"
        ),
    },
    TestVector {
        d: &hex!(
            "b5f670e98d8befc46f6f51fb2997069550c2a52ebfb4e5e25dd905352d9ef89eed5c2ecd16521853aadb1b52b8c42ae6"
        ),
        q_x: &hex!(
            "44ffb2a3a95e12d87c72b5ea0a8a7cb89f56b3bd46342b2303608d7216301c21b5d2921d80b6628dc512ccb84e2fc278"
        ),
        q_y: &hex!(
            "e4c1002f1828abaec768cadcb7cf42fbf93b1709ccae6df5b134c41fae2b9a188bfbe1eccff0bd348517d7227f2071a6"
        ),
        k: &hex!(
            "229e67638f712f57bea4c2b02279d5ccad1e7c9e201c77f6f01aeb81ea90e62b44b2d2107fd66d35e56608fff65e28e4"
        ),
        m: &hex!(
            "b2acf6b4ae1ba9985c1e657313d59157939c21868302f6f5c5dbf037867035ae7c2009bad9fce472579923f7b4b87795"
        ),
        r: &hex!(
            "b11db592e4ebc75b6472b879b1d8ce57452c615aef20f67a280f8bca9b11a30ad4ac9d69541258c7dd5d0b4ab8dd7d49"
        ),
        s: &hex!(
            "4eb51db8004e46d438359abf060a9444616cb46b4f99c9a05b53ba6df02e914c9c0b6cc3a9791d804d2e4c0984dab1cc"
        ),
    },
    TestVector {
        d: &hex!(
            "de5975d8932533f092e76295ed6b23f10fc5fba48bfb82c6cc714826baf0126813247f8bd51d5738503654ab22459976"
        ),
        q_x: &hex!(
            "f1fabafc01fec7e96d982528d9ef3a2a18b7fe8ae0fa0673977341c7ae4ae8d8d3d67420343d013a984f5f61da29ae38"
        ),
        q_y: &hex!(
            "1a31cf902c46343d01b2ebb614bc789c313b5f91f9302ad9418e9c797563e2fa3d44500f47b4e26ad8fdec1a816d1dcf"
        ),
        k: &hex!(
            "fc5940e661542436f9265c34bce407eff6364bd471aa79b90c906d923e15c9ed96eea4e86f3238ea86161d13b7d9359d"
        ),
        m: &hex!(
            "ec21c9d03a7270ea9ce7e9ff83211bac2fb104d078217c370248a3aba81f6c586852f19ced56dc71f83f5251d7381c8a"
        ),
        r: &hex!(
            "c2fbdd6a56789024082173725d797ef9fd6accb6ae664b7260f9e83cb8ab2490428c8b9c52e153612295432fec4d59cd"
        ),
        s: &hex!(
            "8056c5bb57f41f73082888b234fcda320a33250b5da012ba1fdb4924355ae679012d81d2c08fc0f8634c708a4833232f"
        ),
    },
    TestVector {
        d: &hex!(
            "11e0d470dc31fab0f5722f87b74a6c8d7414115e58ceb38bfcdced367beac3adbf1fe9ba5a04f72e978b1eb54597eabc"
        ),
        q_x: &hex!(
            "1950166989164cbfd97968c7e8adb6fbca1873ebef811ea259eb48b7d584627f0e6d6c64defe23cbc95236505a252aa1"
        ),
        q_y: &hex!(
            "41ef424b5cb076d4e32accd9250ea75fcf4ffd81814040c050d58c0a29b06be11edf67c911b403e418b7277417e52906"
        ),
        k: &hex!(
            "e56904028226eb04f8d071e3f9cefec91075a81ca0fa87b44cae148fe1ce9827b5d1910db2336d0eb9813ddba3e4d7b5"
        ),
        m: &hex!(
            "f0272d0a51ee61f86d0875ca7800e12744ef6ffbac72bdda7c54ba24e5a5a6bd69ebe6f429cc20ac12b926d392efc4ce"
        ),
        r: &hex!(
            "c38ef30f55624e8935680c29f8c24824877cf48ffc0ef015e62de1068893353030d1193bf9d34237d7ce6ba92c98b0fe"
        ),
        s: &hex!(
            "651b8c3d5c9d5b936d300802a06d82ad54f7b1ba4327b2f031c0c5b0cb215ad4354edc7f932d934e877dfa1cf51b13fe"
        ),
    },
    TestVector {
        d: &hex!(
            "5c6bbf9fbcbb7b97c9535f57b431ed1ccae1945b7e8a4f1b032016b07810bd24a9e20055c0e9306650df59ef7e2cd8c2"
        ),
        q_x: &hex!(
            "2e01c5b59e619e00b79060a1e8ef695472e23bf9a511fc3d5ed77a334a242557098e40972713732c5291c97adf9cf2cf"
        ),
        q_y: &hex!(
            "563e3fe4ad807e803b9e961b08da4dde4cea8925649da0d93221ce4cdceabc6a1db7612180a8c6bef3579c65539b97e9"
        ),
        k: &hex!(
            "03d23f1277b949cb6380211ad9d338e6f76c3eedac95989b91d0243cfb734a54b19bca45a5d13d6a4b9f815d919eea77"
        ),
        m: &hex!(
            "e114c6204bee5bf0bbdf9ffc139bb99f09e7ea2186da3ee1e011dd059185d57c4953a130d34ff0df3fc6782dda199ee8"
        ),
        r: &hex!(
            "abab65308f0b79c4f3a9ff28dd490acb0c320434094cef93e75adfe17e5820dc1f77544cfaaacdc8cf9ac8b38e174bef"
        ),
        s: &hex!(
            "11b783d879a6de054b316af7d56e526c3dce96c85289122e3ad927cfa77bfc50b4a96c97f85b1b8221be2df083ff58fb"
        ),
    },
    TestVector {
        d: &hex!(
            "ffc7dedeff8343721f72046bc3c126626c177b0e48e247f44fd61f8469d4d5f0a74147fabaa334495cc1f986ebc5f0b1"
        ),
        q_x: &hex!(
            "51c78c979452edd53b563f63eb3e854a5b23e87f1b2103942b65f77d024471f75c8ce1cc0dfef83292b368112aa5126e"
        ),
        q_y: &hex!(
            "313e6aaf09caa3ba30f13072b2134878f14a4a01ee86326cccbff3d079b4df097dc57985e8c8c834a10cb9d766169366"
        ),
        k: &hex!(
            "c3de91dbe4f777698773da70dd610ef1a7efe4dc00d734399c7dd100728006a502822a5a7ff9129ffd8adf6c1fc1211a"
        ),
        m: &hex!(
            "f11e38f4037ae3ffd0fde97c08e2e5acbc26e3ac5828a86c182232be90ef6fc0f5d21a9b1a7b93472d78c103b4136019"
        ),
        r: &hex!(
            "f4f477855819ad8b1763f53691b76afbc4a31a638b1e08c293f9bcd55decf797f9913ca128d4b45b2e2ea3e82c6cf565"
        ),
        s: &hex!(
            "7c26be29569ef95480a6d0c1af49dc10a51a0a8931345e48c0c39498bfb94d62962980b56143a7b41a2fddc8794c1b7f"
        ),
    },
    TestVector {
        d: &hex!(
            "adca364ef144a21df64b163615e8349cf74ee9dbf728104215c532073a7f74e2f67385779f7f74ab344cc3c7da061cf6"
        ),
        q_x: &hex!(
            "ef948daae68242330a7358ef73f23b56c07e37126266db3fa6eea233a04a9b3e4915233dd6754427cd4b71b75854077d"
        ),
        q_y: &hex!(
            "009453ef1828eaff9e17c856d4fc1895ab60051312c3e1db1e3766566438b2990cbf9945c2545619e3e0145bc6a79004"
        ),
        k: &hex!(
            "a2da3fae2e6da3cf11b49861afb34fba357fea89f54b35ce5ed7434ae09103fe53e2be75b93fc579fedf919f6d5e407e"
        ),
        m: &hex!(
            "f8d0170479b2d1a8f50c80556e67ff345592c8b7dcda4e4f6099f993c1a71bff6d3b60190715ae1215a8a759a8eb13df"
        ),
        r: &hex!(
            "dda994b9c428b57e9f8bbaebba0d682e3aac6ed828e3a1e99a7fc4c804bff8df151137f539c7389d80e23d9f3ee497bf"
        ),
        s: &hex!(
            "a0d6b10ceffd0e1b29cf784476f9173ba6ecd2cfc7929725f2d6e24e0db5a4721683640eaa2bbe151fb57560f9ce594b"
        ),
    },
    TestVector {
        d: &hex!(
            "39bea008ec8a217866dcbdb1b93da34d1d3e851d011df9ef44b7828b3453a54aa70f1df9932170804eacd207e4f7e91d"
        ),
        q_x: &hex!(
            "5709ec4305a9c3271c304face6c148142490b827a73a4c17affcfd01fffd7eaa65d2fdedfa2419fc64ed910823513faf"
        ),
        q_y: &hex!(
            "b083cda1cf3be6371b6c06e729ea6299213428db57119347247ec1fcd44204386cc0bca3f452d9d864b39efbfc89d6b2"
        ),
        k: &hex!(
            "3c90cc7b6984056f570542a51cbe497ce4c11aeae8fc35e8fd6a0d9adeb650e8644f9d1d5e4341b5adc81e27f284c08f"
        ),
        m: &hex!(
            "86bc7536faf2de20028159ce93e293d0a7f5721fb6680b5b070c3f70aba845de2eaed9245144babc38c49cce59f3eac7"
        ),
        r: &hex!(
            "d13646895afb1bfd1953551bb922809c95ad65d6abe94eb3719c899aa1f6dba6b01222c7f283900fe98628b7597b6ea6"
        ),
        s: &hex!(
            "4a9a38afda04c0a6b0058943b679bd02205b14d0f3d49b8f31aac289129780cdb1c555def8c3f9106b478729e0c7efaa"
        ),
    },
    TestVector {
        d: &hex!(
            "e849cf948b241362e3e20c458b52df044f2a72deb0f41c1bb0673e7c04cdd70811215059032b5ca3cc69c345dcce4cf7"
        ),
        q_x: &hex!(
            "06c037a0cbf43fdf335dff33de06d34348405353f9fdf2ce1361efba30fb204aea9dbd2e30da0a10fd2d876188371be6"
        ),
        q_y: &hex!(
            "360d38f3940e34679204b98fbf70b8a4d97f25443e46d0807ab634ed5891ad864dd7703557aa933cd380e26eea662a43"
        ),
        k: &hex!(
            "32386b2593c85e877b70e5e5495936f65dc49553caef1aa6cc14d9cd370c442a0ccfab4c0da9ec311b67913b1b575a9d"
        ),
        m: &hex!(
            "1128c8b09573a993adaa0a68f3ca965db30870db46de70d29e3b9a7d110ba0cd57633f1713173c62331b36fb925fa874"
        ),
        r: &hex!(
            "5886078d3495767e330c7507b7ca0fa07a50e59912a416d89f0ab1aa4e88153d6eaf00882d1b4aa64153153352d853b5"
        ),
        s: &hex!(
            "2cc10023bf1bf8ccfd14b06b82cc2114449a352389c8ff9f6f78cdc4e32bde69f3869da0e17f691b329682ae7a36e1aa"
        ),
    },
    TestVector {
        d: &hex!(
            "d89607475d509ef23dc9f476eae4280c986de741b63560670fa2bd605f5049f1972792c0413a5b3b4b34e7a38b70b7ca"
        ),
        q_x: &hex!(
            "49a1c631f31cf5c45b2676b1f130cbf9be683d0a50dffae0d147c1e9913ab1090c6529a84f47ddc7cf025921b771355a"
        ),
        q_y: &hex!(
            "1e207eece62f2bcc6bdabc1113158145170be97469a2904eaaa93aad85b86a19719207f3e423051f5b9cbbe2754eefcb"
        ),
        k: &hex!(
            "78613c570c8d33b7dd1bd1561d87e36282e8cf4843e7c344a2b2bb6a0da94756d670eeaffe434f7ae7c780f7cf05ca08"
        ),
        m: &hex!(
            "ab9a6d22c8d7675bc8e99e3cafed8318f33051ba5398ce0e9d8e8d3d537a6a908d4c2ace3e6d8204d0236d863eee3c28"
        ),
        r: &hex!(
            "66f92b39aa3f4aeb9e2dc03ac3855406fa3ebbab0a6c88a78d7a03482f0c9868d7b78bc081ede0947c7f37bf193074ba"
        ),
        s: &hex!(
            "e5c64ed98d7f3701193f25dd237d59c91c0da6e26215e0889d82e6d3e416693f8d58843cf30ab10ab8d0edd9170b53ad"
        ),
    },
    TestVector {
        d: &hex!(
            "083e7152734adf342520ae377087a223688de2899b10cfcb34a0b36bca500a4dfa530e2343e6a39da7ae1eb0862b4a0d"
        ),
        q_x: &hex!(
            "70a0f16b6c61172659b027ed19b18fd8f57bd28dc0501f207bd6b0bb065b5671cf3dd1ed13d388dcf6ccc766597aa604"
        ),
        q_y: &hex!(
            "4f845bf01c3c3f6126a7368c3454f51425801ee0b72e63fb6799b4420bfdebe3e37c7246db627cc82c09654979c700bb"
        ),
        k: &hex!(
            "28096ababe29a075fbdf894709a20d0fdedb01ed3eeacb642a33a0da6aed726e13caf6cf206792ec359f0c9f9b567552"
        ),
        m: &hex!(
            "68f858243fe465eb91dc2481333cbb1958883ef25099d45cf02721d17d2846d2cec4689884ae7c0412332e035a1fa3fc"
        ),
        r: &hex!(
            "ee2923f9b9999ea05b5e57f505bed5c6ba0420def42c6fa90eef7a6ef770786525546de27cdeb2f8586f8f29fb4ee67c"
        ),
        s: &hex!(
            "50ef923fb217c4cf65a48b94412fda430fac685f0da7bd574557c6c50f5b22e0c8354d99f2c2f2c2691f252f93c7d84a"
        ),
    },
    TestVector {
        d: &hex!(
            "63578d416215aff2cc78f9b926d4c7740a77c142944e104aa7422b19a616898262d46a8a942d5e8d5db135ee8b09a368"
        ),
        q_x: &hex!(
            "cadbacef4406099316db2ce3206adc636c2bb0a835847ed7941efb02862472f3150338f13f4860d47f39b7e098f0a390"
        ),
        q_y: &hex!(
            "752ad0f22c9c264336cde11bbc95d1816ed4d1b1500db6b8dce259a42832e613c31178c2c7995206a62e201ba108f570"
        ),
        k: &hex!(
            "7b69c5d5b4d05c9950dc94c27d58403b4c52c004b80a80418ad3a89aabc5d34f21926729e76afd280cc8ee88c9805a2a"
        ),
        m: &hex!(
            "dca5ebfebeac1696eff4a89162469c6937b80f8f8cf17299856de2e13d8f8a199bff3085cee59366886164bcc03f7e90"
        ),
        r: &hex!(
            "db054addb6161ee49c6ce2e4d646d7670754747b6737ca8516e9d1e87859937c3ef9b1d2663e10d7e4bd00ec85b7a97a"
        ),
        s: &hex!(
            "fcc504e0f00ef29587e4bc22faada4db30e2cb1ac552680a65785ae87beb666c792513f2be7a3180fc544296841a0e27"
        ),
    },
    TestVector {
        d: &hex!(
            "ed4df19971658b74868800b3b81bc877807743b25c65740f1d6377542afe2c6427612c840ada31a8eb794718f37c7283"
        ),
        q_x: &hex!(
            "33093a0568757e8b58df5b72ea5fe5bf26e6f7aeb541b4c6a8c189c93721749bcaceccf2982a2f0702586a9f812fc66f"
        ),
        q_y: &hex!(
            "ebe320d09e1f0662189d50b85a20403b821ac0d000afdbf66a0a33f304726c69e354d81c50b94ba3a5250efc31319cd1"
        ),
        k: &hex!(
            "d9b4cd1bdfa83e608289634dbfcee643f07315baf743fc91922880b55a2feda3b38ddf6040d3ba10985cd1285fc690d5"
        ),
        m: &hex!(
            "f9b152150f7dc99d5262c9da04dde148009730fb2af9ac753b9c64488d27c817f68c17ae1ff61e50ebb6749230c59a71"
        ),
        r: &hex!(
            "009c74063e206a4259b53decff5445683a03f44fa67252b76bd3581081c714f882f882df915e97dbeab061fa8b3cc4e7"
        ),
        s: &hex!(
            "d40e09d3468b46699948007e8f59845766dbf694b9c62066890dd055c0cb9a0caf0aa611fb9f466ad0bbb00dbe29d7eb"
        ),
    },
    TestVector {
        d: &hex!(
            "e9c7e9a79618d6ff3274da1abd0ff3ed0ec1ae3b54c3a4fd8d68d98fb04326b7633fc637e0b195228d0edba6bb1468fb"
        ),
        q_x: &hex!(
            "a39ac353ca787982c577aff1e8601ce192aa90fd0de4c0ed627f66a8b6f02ae51315543f72ffc1c48a7269b25e7c289a"
        ),
        q_y: &hex!(
            "9064a507b66b340b6e0e0d5ffaa67dd20e6dafc0ea6a6faee1635177af256f9108a22e9edf736ab4ae8e96dc207b1fa9"
        ),
        k: &hex!(
            "b094cb3a5c1440cfab9dc56d0ec2eff00f2110dea203654c70757254aa5912a7e73972e607459b1f4861e0b08a5cc763"
        ),
        m: &hex!(
            "14f785ebb5a3b1bdff516a6b580e245b3c81aff37e1035e354b084a6691e973e0de30bb2a0490fca2d757f8191d7560a"
        ),
        r: &hex!(
            "ee82c0f90501136eb0dc0e459ad17bf3be1b1c8b8d05c60068a9306a346326ff7344776a95f1f7e2e2cf9477130e735c"
        ),
        s: &hex!(
            "af10b90f203af23b7500e070536e64629ba19245d6ef39aab57fcdb1b73c4c6bf7070c6263544633d3d358c12a178138"
        ),
    },
];
