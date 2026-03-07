SUMMARY = "RTL-SDR Blog fork - turns RTL2832U dongle into a SDR receiver"
DESCRIPTION = "Modified Osmocom drivers with enhancements for RTL-SDR Blog V3 and V4 units"
HOMEPAGE = "https://github.com/rtlsdrblog/rtl-sdr-blog"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=751419260aa954499f7abaabaa882bbe"

DEPENDS = "libusb1"

SRC_URI = "git://github.com/rtlsdrblog/rtl-sdr-blog.git;protocol=https;branch=master"
SRCREV = "${AUTOREV}"
PV = "1.3.6+git"

S = "${WORKDIR}/git"

inherit cmake pkgconfig

EXTRA_OECMAKE = " \
    -DINSTALL_UDEV_RULES=OFF \
    -DDETACH_KERNEL_DRIVER=ON \
"

do_install:append() {
    # Install udev rules so the dongle is accessible without root
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${S}/rtl-sdr.rules ${D}${sysconfdir}/udev/rules.d/99-rtl-sdr.rules

    # Blacklist the DVB kernel driver so it doesn't grab the device
    install -d ${D}${sysconfdir}/modprobe.d
    echo "blacklist dvb_usb_rtl28xxu" > ${D}${sysconfdir}/modprobe.d/blacklist-rtl-sdr.conf
}

FILES:${PN} += " \
    ${sysconfdir}/udev/rules.d/*.rules \
    ${sysconfdir}/modprobe.d/*.conf \
"

FILES:${PN}-dev += "${libdir}/cmake"

RDEPENDS:${PN} = "libusb1"
