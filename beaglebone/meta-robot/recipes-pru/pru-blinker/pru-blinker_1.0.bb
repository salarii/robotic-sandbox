SUMMARY = "PRU Blinker firmware for BeagleBone Black"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://pru_main.c \
           file://AM335x_PRU.cmd"

S = "${WORKDIR}"

DEPENDS = "ti-cgt-pru-native pru-icss"

PRU_CGT = "${STAGING_DIR_NATIVE}/usr/share/ti/cgt-pru"

do_compile() {
    ${PRU_CGT}/bin/clpru \
        --include_path=${PRU_CGT}/include \
        --include_path=${STAGING_INCDIR}/am335x \
        -v3 -O2 --printf_support=minimal \
        pru_main.c \
        -z AM335x_PRU.cmd \
        -l${PRU_CGT}/lib/libc.a \
        --output_file=pru-blinker.out
}

do_install() {
    install -d ${D}/lib/firmware
    install -m 0644 pru-blinker.out ${D}/lib/firmware/am335x-pru0-fw
}

FILES:${PN} = "/lib/firmware/am335x-pru0-fw"
INSANE_SKIP:${PN} = "arch"