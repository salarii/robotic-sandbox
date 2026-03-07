SUMMARY = "Rust app to read raw IQ frames from RTL-SDR dongle"
LICENSE = "CLOSED"

inherit cargo

DEPENDS = "rtl-sdr"

SRC_URI = " \
    file://Cargo.toml \
    file://Cargo.lock \
    file://src/main.rs \
"

SRC_URI += " \
    crate://crates.io/libc/0.2.182 \
    crate://crates.io/rtlsdr/0.1.4 \
"

SRC_URI[libc-0.2.182.sha256sum] = "6800badb6cb2082ffd7b6a67e6125bb39f18782f793520caee8cb8846be06112"
SRC_URI[rtlsdr-0.1.4.sha256sum] = "136ba5e46b0edd188e277916fed8f5a7f6810622ec49e03831244f79c7cdfb3e"

S = "${WORKDIR}"

RDEPENDS:${PN} = "rtl-sdr"
