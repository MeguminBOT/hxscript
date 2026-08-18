# The arm64 machine this repository does not have.
#
# hashlink's jit is x86-64 only, so there is no arm64 HashLink to install and no arm64 machine here
# to build one on. This is both: an emulated arm64 Debian with libhl built from the same hashlink the
# vendored loader was taken from, which is what the native module has to be compiled and linked
# against for its struct layouts to line up.
#
# Only libhl is built. hl.exe cannot be: it links jit.c, which is the file this whole branch exists
# because of. Once the JIT compiles a function, hl itself becomes buildable here with ours in its
# place, and that is a later gate rather than a prerequisite of this one.
FROM --platform=linux/arm64 debian:bookworm-slim

RUN apt-get update \
	&& apt-get install -y --no-install-recommends build-essential ca-certificates curl \
	&& rm -rf /var/lib/apt/lists/*

# The tag, not a branch, and the same one src/hxscript/hl/native/vendor/hl116 was taken from. A libhl
# built from anything else shares its name with the carried loader and not its structure layouts.
ARG HL_VERSION=1.16

RUN curl -fsSL "https://github.com/HaxeFoundation/hashlink/archive/refs/tags/${HL_VERSION}.tar.gz" \
		| tar xz -C /opt \
	&& mv "/opt/hashlink-${HL_VERSION}" /opt/hashlink

WORKDIR /opt/hashlink

# Laid out the way a binary distribution is, because that is where build.sh and Native.hx look: hl.h
# under include/, the library under lib/.
RUN make libhl.so \
	&& mkdir -p /opt/hl/include /opt/hl/lib \
	&& cp libhl.so* /opt/hl/lib/ \
	&& cp src/hl.h src/hlc.h src/hl_ffi.h src/hlc_main.c /opt/hl/include/ \
	&& echo /opt/hl/lib > /etc/ld.so.conf.d/hl.conf \
	&& ldconfig

ENV HLPATH=/opt/hl
WORKDIR /work
