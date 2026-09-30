#!/bin/sh
#
# Work out which Alpine packages the runtime image needs by asking the built
# objects, instead of keeping a second hand-written list in step with the first.
#
# Every ELF object records the SONAMEs it needs, and every Alpine package
# advertises the SONAMEs it ships as `so:<soname>` provides.  Printing the union
# of the first and handing it to `apk add` therefore reproduces the link-time
# dependency set exactly -- including anything deps.sh discovered on its own, and
# including SONAME bumps, which is where a hand-written `apk add libfoo` list
# usually rots.
#
# Usage: runtime.sh <dir>...   e.g. runtime.sh /stage /usr/local/lib

set -eu

[ $# -gt 0 ] || { echo "usage: runtime.sh <dir>..." >&2; exit 1; }

scanelf --quiet --recursive --nobanner --needed --format '%n#F' "$@" |
	cut -d'#' -f1 |
	tr ',' '\n' |
	sort -u |
	while read -r soname; do
		[ -n "$soname" ] || continue
		# Libraries built from source in the media stage travel with the
		# image as files, not as packages, so apk has no provider for
		# them and must not be asked for one.
		[ -e "/usr/local/lib/$soname" ] && continue
		printf 'so:%s\n' "$soname"
	done
