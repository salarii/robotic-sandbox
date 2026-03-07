SUMMARY = "Rust app to read raw IQ frames from RTL-SDR dongle"
LICENSE = "CLOSED"

inherit cargo

DEPENDS = "libusb1"

SRC_URI = " \
    file://Cargo.toml \
    file://Cargo.lock \
    file://src/main.rs \
"

SRC_URI += " \
    crate://crates.io/aho-corasick/1.1.4 \
    crate://crates.io/autocfg/1.5.0 \
    crate://crates.io/byteorder/1.5.0 \
    crate://crates.io/cc/1.2.56 \
    crate://crates.io/cfg-if/1.0.4 \
    crate://crates.io/difflib/0.4.0 \
    crate://crates.io/downcast/0.11.0 \
    crate://crates.io/either/1.15.0 \
    crate://crates.io/find-msvc-tools/0.1.9 \
    crate://crates.io/float-cmp/0.9.0 \
    crate://crates.io/fragile/2.0.1 \
    crate://crates.io/itertools/0.10.5 \
    crate://crates.io/lazy_static/1.5.0 \
    crate://crates.io/libc/0.2.182 \
    crate://crates.io/libusb1-sys/0.7.0 \
    crate://crates.io/log/0.4.29 \
    crate://crates.io/memchr/2.8.0 \
    crate://crates.io/mockall/0.11.4 \
    crate://crates.io/mockall_derive/0.11.4 \
    crate://crates.io/normalize-line-endings/0.3.0 \
    crate://crates.io/num-traits/0.2.19 \
    crate://crates.io/pkg-config/0.3.32 \
    crate://crates.io/predicates/2.1.5 \
    crate://crates.io/predicates-core/1.0.10 \
    crate://crates.io/predicates-tree/1.0.13 \
    crate://crates.io/proc-macro2/1.0.106 \
    crate://crates.io/quote/1.0.45 \
    crate://crates.io/regex/1.12.3 \
    crate://crates.io/regex-automata/0.4.14 \
    crate://crates.io/regex-syntax/0.8.10 \
    crate://crates.io/rtl-sdr-rs/0.3.1 \
    crate://crates.io/rusb/0.9.4 \
    crate://crates.io/shlex/1.3.0 \
    crate://crates.io/syn/1.0.109 \
    crate://crates.io/termtree/0.5.1 \
    crate://crates.io/unicode-ident/1.0.24 \
    crate://crates.io/vcpkg/0.2.15 \
"

SRC_URI[aho-corasick-1.1.4.sha256sum] = "ddd31a130427c27518df266943a5308ed92d4b226cc639f5a8f1002816174301"
SRC_URI[autocfg-1.5.0.sha256sum] = "c08606f8c3cbf4ce6ec8e28fb0014a2c086708fe954eaa885384a6165172e7e8"
SRC_URI[byteorder-1.5.0.sha256sum] = "1fd0f2584146f6f2ef48085050886acf353beff7305ebd1ae69500e27c67f64b"
SRC_URI[cc-1.2.56.sha256sum] = "aebf35691d1bfb0ac386a69bac2fde4dd276fb618cf8bf4f5318fe285e821bb2"
SRC_URI[cfg-if-1.0.4.sha256sum] = "9330f8b2ff13f34540b44e946ef35111825727b38d33286ef986142615121801"
SRC_URI[difflib-0.4.0.sha256sum] = "6184e33543162437515c2e2b48714794e37845ec9851711914eec9d308f6ebe8"
SRC_URI[downcast-0.11.0.sha256sum] = "1435fa1053d8b2fbbe9be7e97eca7f33d37b28409959813daefc1446a14247f1"
SRC_URI[either-1.15.0.sha256sum] = "48c757948c5ede0e46177b7add2e67155f70e33c07fea8284df6576da70b3719"
SRC_URI[find-msvc-tools-0.1.9.sha256sum] = "5baebc0774151f905a1a2cc41989300b1e6fbb29aff0ceffa1064fdd3088d582"
SRC_URI[float-cmp-0.9.0.sha256sum] = "98de4bbd547a563b716d8dfa9aad1cb19bfab00f4fa09a6a4ed21dbcf44ce9c4"
SRC_URI[fragile-2.0.1.sha256sum] = "28dd6caf6059519a65843af8fe2a3ae298b14b80179855aeb4adc2c1934ee619"
SRC_URI[itertools-0.10.5.sha256sum] = "b0fd2260e829bddf4cb6ea802289de2f86d6a7a690192fbe91b3f46e0f2c8473"
SRC_URI[lazy_static-1.5.0.sha256sum] = "bbd2bcb4c963f2ddae06a2efc7e9f3591312473c50c6685e1f298068316e66fe"
SRC_URI[libc-0.2.182.sha256sum] = "6800badb6cb2082ffd7b6a67e6125bb39f18782f793520caee8cb8846be06112"
SRC_URI[libusb1-sys-0.7.0.sha256sum] = "da050ade7ac4ff1ba5379af847a10a10a8e284181e060105bf8d86960ce9ce0f"
SRC_URI[log-0.4.29.sha256sum] = "5e5032e24019045c762d3c0f28f5b6b8bbf38563a65908389bf7978758920897"
SRC_URI[memchr-2.8.0.sha256sum] = "f8ca58f447f06ed17d5fc4043ce1b10dd205e060fb3ce5b979b8ed8e59ff3f79"
SRC_URI[mockall-0.11.4.sha256sum] = "4c84490118f2ee2d74570d114f3d0493cbf02790df303d2707606c3e14e07c96"
SRC_URI[mockall_derive-0.11.4.sha256sum] = "22ce75669015c4f47b289fd4d4f56e894e4c96003ffdf3ac51313126f94c6cbb"
SRC_URI[normalize-line-endings-0.3.0.sha256sum] = "61807f77802ff30975e01f4f071c8ba10c022052f98b3294119f3e615d13e5be"
SRC_URI[num-traits-0.2.19.sha256sum] = "071dfc062690e90b734c0b2273ce72ad0ffa95f0c74596bc250dcfd960262841"
SRC_URI[pkg-config-0.3.32.sha256sum] = "7edddbd0b52d732b21ad9a5fab5c704c14cd949e5e9a1ec5929a24fded1b904c"
SRC_URI[predicates-2.1.5.sha256sum] = "59230a63c37f3e18569bdb90e4a89cbf5bf8b06fea0b84e65ea10cc4df47addd"
SRC_URI[predicates-core-1.0.10.sha256sum] = "cad38746f3166b4031b1a0d39ad9f954dd291e7854fcc0eed52ee41a0b50d144"
SRC_URI[predicates-tree-1.0.13.sha256sum] = "d0de1b847b39c8131db0467e9df1ff60e6d0562ab8e9a16e568ad0fdb372e2f2"
SRC_URI[proc-macro2-1.0.106.sha256sum] = "8fd00f0bb2e90d81d1044c2b32617f68fcb9fa3bb7640c23e9c748e53fb30934"
SRC_URI[quote-1.0.45.sha256sum] = "41f2619966050689382d2b44f664f4bc593e129785a36d6ee376ddf37259b924"
SRC_URI[regex-1.12.3.sha256sum] = "e10754a14b9137dd7b1e3e5b0493cc9171fdd105e0ab477f51b72e7f3ac0e276"
SRC_URI[regex-automata-0.4.14.sha256sum] = "6e1dd4122fc1595e8162618945476892eefca7b88c52820e74af6262213cae8f"
SRC_URI[regex-syntax-0.8.10.sha256sum] = "dc897dd8d9e8bd1ed8cdad82b5966c3e0ecae09fb1907d58efaa013543185d0a"
SRC_URI[rtl-sdr-rs-0.3.1.sha256sum] = "b3e39d1d957178d9bc3d2641e41ea083205f304b6b2db4f6efd60bc45498aa82"
SRC_URI[rusb-0.9.4.sha256sum] = "ab9f9ff05b63a786553a4c02943b74b34a988448671001e9a27e2f0565cc05a4"
SRC_URI[shlex-1.3.0.sha256sum] = "0fda2ff0d084019ba4d7c6f371c95d8fd75ce3524c3cb8fb653a3023f6323e64"
SRC_URI[syn-1.0.109.sha256sum] = "72b64191b275b66ffe2469e8af2c1cfe3bafa67b529ead792a6d0160888b4237"
SRC_URI[termtree-0.5.1.sha256sum] = "8f50febec83f5ee1df3015341d8bd429f2d1cc62bcba7ea2076759d315084683"
SRC_URI[unicode-ident-1.0.24.sha256sum] = "e6e4313cd5fcd3dad5cafa179702e2b244f760991f45397d14d4ebf38247da75"
SRC_URI[vcpkg-0.2.15.sha256sum] = "accd4ea62f7bb7a82fe23066fb0957d48ef677f6eeb8215f372f52e48bb32426"

S = "${WORKDIR}"

RDEPENDS:${PN} = "libusb1"
