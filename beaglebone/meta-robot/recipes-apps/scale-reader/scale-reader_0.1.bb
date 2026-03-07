SUMMARY = "Rust application to read HX711 load cell"
LICENSE = "CLOSED"

inherit cargo

SRC_URI = " \
    file://Cargo.toml \
    file://Cargo.lock \
    file://src/main.rs \
"

SRC_URI += " \
    crate://crates.io/autocfg/1.5.0 \
    crate://crates.io/bitflags/1.3.2 \
    crate://crates.io/bitflags/2.11.0 \
    crate://crates.io/byteorder/1.5.0 \
    crate://crates.io/cast/0.3.0 \
    crate://crates.io/cc/1.2.56 \
    crate://crates.io/cfg-if/1.0.4 \
    crate://crates.io/core-foundation/0.10.0 \
    crate://crates.io/core-foundation-sys/0.8.7 \
    crate://crates.io/embedded-hal/1.0.0 \
    crate://crates.io/embedded-hal-nb/1.0.0 \
    crate://crates.io/find-msvc-tools/0.1.9 \
    crate://crates.io/gpio-cdev/0.6.0 \
    crate://crates.io/hx711/0.7.0 \
    crate://crates.io/i2cdev/0.6.2 \
    crate://crates.io/io-kit-sys/0.4.1 \
    crate://crates.io/libc/0.2.182 \
    crate://crates.io/linux-embedded-hal/0.4.1 \
    crate://crates.io/mach2/0.4.3 \
    crate://crates.io/memoffset/0.6.5 \
    crate://crates.io/memoffset/0.7.1 \
    crate://crates.io/nb/1.1.0 \
    crate://crates.io/nix/0.23.2 \
    crate://crates.io/nix/0.26.4 \
    crate://crates.io/nix/0.27.1 \
    crate://crates.io/pin-utils/0.1.0 \
    crate://crates.io/proc-macro2/1.0.106 \
    crate://crates.io/quote/1.0.40 \
    crate://crates.io/scopeguard/1.2.0 \
    crate://crates.io/serialport/4.8.1 \
    crate://crates.io/shlex/1.3.0 \
    crate://crates.io/spidev/0.6.1 \
    crate://crates.io/syn/2.0.117 \
    crate://crates.io/sysfs_gpio/0.6.2 \
    crate://crates.io/thiserror/2.0.18 \
    crate://crates.io/thiserror-impl/2.0.18 \
    crate://crates.io/unescaper/0.1.8 \
    crate://crates.io/unicode-ident/1.0.24 \
    crate://crates.io/windows-sys/0.52.0 \
    crate://crates.io/windows-targets/0.52.6 \
    crate://crates.io/windows_aarch64_gnullvm/0.52.6 \
    crate://crates.io/windows_aarch64_msvc/0.52.6 \
    crate://crates.io/windows_i686_gnu/0.52.6 \
    crate://crates.io/windows_i686_gnullvm/0.52.6 \
    crate://crates.io/windows_i686_msvc/0.52.6 \
    crate://crates.io/windows_x86_64_gnu/0.52.6 \
    crate://crates.io/windows_x86_64_gnullvm/0.52.6 \
    crate://crates.io/windows_x86_64_msvc/0.52.6 \
"

SRC_URI[autocfg-1.5.0.sha256sum] = "c08606f8c3cbf4ce6ec8e28fb0014a2c086708fe954eaa885384a6165172e7e8"
SRC_URI[bitflags-1.3.2.sha256sum] = "bef38d45163c2f1dde094a7dfd33ccf595c92905c8f8f4fdc18d06fb1037718a"
SRC_URI[bitflags-2.11.0.sha256sum] = "843867be96c8daad0d758b57df9392b6d8d271134fce549de6ce169ff98a92af"
SRC_URI[byteorder-1.5.0.sha256sum] = "1fd0f2584146f6f2ef48085050886acf353beff7305ebd1ae69500e27c67f64b"
SRC_URI[cast-0.3.0.sha256sum] = "37b2a672a2cb129a2e41c10b1224bb368f9f37a2b16b612598138befd7b37eb5"
SRC_URI[cc-1.2.56.sha256sum] = "aebf35691d1bfb0ac386a69bac2fde4dd276fb618cf8bf4f5318fe285e821bb2"
SRC_URI[cfg-if-1.0.4.sha256sum] = "9330f8b2ff13f34540b44e946ef35111825727b38d33286ef986142615121801"
SRC_URI[core-foundation-0.10.0.sha256sum] = "b55271e5c8c478ad3f38ad24ef34923091e0548492a266d19b3c0b4d82574c63"
SRC_URI[core-foundation-sys-0.8.7.sha256sum] = "773648b94d0e5d620f64f280777445740e61fe701025087ec8b57f45c791888b"
SRC_URI[embedded-hal-1.0.0.sha256sum] = "361a90feb7004eca4019fb28352a9465666b24f840f5c3cddf0ff13920590b89"
SRC_URI[embedded-hal-nb-1.0.0.sha256sum] = "fba4268c14288c828995299e59b12babdbe170f6c6d73731af1b4648142e8605"
SRC_URI[find-msvc-tools-0.1.9.sha256sum] = "5baebc0774151f905a1a2cc41989300b1e6fbb29aff0ceffa1064fdd3088d582"
SRC_URI[gpio-cdev-0.6.0.sha256sum] = "09831ec59b80be69e75d29cf36e16afbbe5fd1af9c1bf4689ad91c77db5aa6a6"
SRC_URI[hx711-0.7.0.sha256sum] = "60c8a5b176b4cba5ff9c01a721bc4758af53717062f251f55553fc73abe627a8"
SRC_URI[i2cdev-0.6.2.sha256sum] = "9b940f7497c4f95b863b21cd34c3737b53a67d80d94cf29055d7f7eeca6ffdb4"
SRC_URI[io-kit-sys-0.4.1.sha256sum] = "617ee6cf8e3f66f3b4ea67a4058564628cde41901316e19f559e14c7c72c5e7b"
SRC_URI[libc-0.2.182.sha256sum] = "6800badb6cb2082ffd7b6a67e6125bb39f18782f793520caee8cb8846be06112"
SRC_URI[linux-embedded-hal-0.4.1.sha256sum] = "2a8a605c95f708c78554738a12153b213f107d3bd5323f7ce32d6deb3faafb40"
SRC_URI[mach2-0.4.3.sha256sum] = "d640282b302c0bb0a2a8e0233ead9035e3bed871f0b7e81fe4a1ec829765db44"
SRC_URI[memoffset-0.6.5.sha256sum] = "5aa361d4faea93603064a027415f07bd8e1d5c88c9fbf68bf56a285428fd79ce"
SRC_URI[memoffset-0.7.1.sha256sum] = "5de893c32cde5f383baa4c04c5d6dbdd735cfd4a794b0debdb2bb1b421da5ff4"
SRC_URI[nb-1.1.0.sha256sum] = "8d5439c4ad607c3c23abf66de8c8bf57ba8adcd1f129e699851a6e43935d339d"
SRC_URI[nix-0.23.2.sha256sum] = "8f3790c00a0150112de0f4cd161e3d7fc4b2d8a5542ffc35f099a2562aecb35c"
SRC_URI[nix-0.26.4.sha256sum] = "598beaf3cc6fdd9a5dfb1630c2800c7acd31df7aaf0f565796fba2b53ca1af1b"
SRC_URI[nix-0.27.1.sha256sum] = "2eb04e9c688eff1c89d72b407f168cf79bb9e867a9d3323ed6c01519eb9cc053"
SRC_URI[pin-utils-0.1.0.sha256sum] = "8b870d8c151b6f2fb93e84a13146138f05d02ed11c7e7c54f8826aaaf7c9f184"
SRC_URI[proc-macro2-1.0.106.sha256sum] = "8fd00f0bb2e90d81d1044c2b32617f68fcb9fa3bb7640c23e9c748e53fb30934"
SRC_URI[quote-1.0.40.sha256sum] = "1885c039570dc00dcb4ff087a89e185fd56bae234ddc7f056a945bf36467248d"
SRC_URI[scopeguard-1.2.0.sha256sum] = "94143f37725109f92c262ed2cf5e59bce7498c01bcc1502d7b9afe439a4e9f49"
SRC_URI[serialport-4.8.1.sha256sum] = "21f60a586160667241d7702c420fc223939fb3c0bb8d3fac84f78768e8970dee"
SRC_URI[shlex-1.3.0.sha256sum] = "0fda2ff0d084019ba4d7c6f371c95d8fd75ce3524c3cb8fb653a3023f6323e64"
SRC_URI[spidev-0.6.1.sha256sum] = "32dadd0a877f0652fa52dbc4d2ed9f4877bea5cd30725507b36e1970a5ef0519"
SRC_URI[syn-2.0.117.sha256sum] = "e665b8803e7b1d2a727f4023456bbbbe74da67099c585258af0ad9c5013b9b99"
SRC_URI[sysfs_gpio-0.6.2.sha256sum] = "e8808c55bc926565c62ef7838bcaa8add51585236803e2bdfa1472e3a3ab5e17"
SRC_URI[thiserror-2.0.18.sha256sum] = "4288b5bcbc7920c07a1149a35cf9590a2aa808e0bc1eafaade0b80947865fbc4"
SRC_URI[thiserror-impl-2.0.18.sha256sum] = "ebc4ee7f67670e9b64d05fa4253e753e016c6c95ff35b89b7941d6b856dec1d5"
SRC_URI[unescaper-0.1.8.sha256sum] = "4064ed685c487dbc25bd3f0e9548f2e34bab9d18cefc700f9ec2dba74ba1138e"
SRC_URI[unicode-ident-1.0.24.sha256sum] = "e6e4313cd5fcd3dad5cafa179702e2b244f760991f45397d14d4ebf38247da75"
SRC_URI[windows-sys-0.52.0.sha256sum] = "282be5f36a8ce781fad8c8ae18fa3f9beff57ec1b52cb3de0789201425d9a33d"
SRC_URI[windows-targets-0.52.6.sha256sum] = "9b724f72796e036ab90c1021d4780d4d3d648aca59e491e6b98e725b84e99973"
SRC_URI[windows_aarch64_gnullvm-0.52.6.sha256sum] = "32a4622180e7a0ec044bb555404c800bc9fd9ec262ec147edd5989ccd0c02cd3"
SRC_URI[windows_aarch64_msvc-0.52.6.sha256sum] = "09ec2a7bb152e2252b53fa7803150007879548bc709c039df7627cabbd05d469"
SRC_URI[windows_i686_gnu-0.52.6.sha256sum] = "8e9b5ad5ab802e97eb8e295ac6720e509ee4c243f69d781394014ebfe8bbfa0b"
SRC_URI[windows_i686_gnullvm-0.52.6.sha256sum] = "0eee52d38c090b3caa76c563b86c3a4bd71ef1a819287c19d586d7334ae8ed66"
SRC_URI[windows_i686_msvc-0.52.6.sha256sum] = "240948bc05c5e7c6dabba28bf89d89ffce3e303022809e73deaefe4f6ec56c66"
SRC_URI[windows_x86_64_gnu-0.52.6.sha256sum] = "147a5c80aabfbf0c7d901cb5895d1de30ef2907eb21fbbab29ca94c5b08b1a78"
SRC_URI[windows_x86_64_gnullvm-0.52.6.sha256sum] = "24d5b23dc417412679681396f2b49f3de8c1473deb516bd34410872eff51ed0d"
SRC_URI[windows_x86_64_msvc-0.52.6.sha256sum] = "589f6da84c646204747d1270a2a5661ea66ed1cced2631d546fdfb155959f9ec"

S = "${WORKDIR}"