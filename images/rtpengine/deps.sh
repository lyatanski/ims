#!/bin/sh
#
# Install rtpengine's build dependencies by reading them out of the source tree
# instead of listing them here.
#
# Upstream states its build inputs in two machine-readable places:
#
#   utils/gen-*-flags  every pkg-config module the build probes.  The required
#                      ones abort the build when missing, but the optional ones
#                      -- bcg729, mosquitto, io_uring, libiptc -- are skipped in
#                      silence, which is exactly how an image ends up without
#                      G.729 and nobody notices for a year.
#   debian/control     Build-Depends, which additionally covers the inputs that
#                      have no pkg-config module at all, such as gperf and
#                      pandoc.
#
# Alpine's -dev subpackages advertise the modules they carry as `pc:<module>`
# provides, so apk can be asked directly who provides a module.  That is the
# whole trick: a dependency the rtpengine developers add tomorrow resolves
# tomorrow with no edit here.  One that cannot be resolved is printed by name
# and fails the build -- a new dependency should stop the build, not disappear
# from the binary.
#
# Usage: deps.sh <rtpengine source dir>

set -eu

src=${1:?usage: deps.sh <rtpengine source dir>}

say() { printf '%s\n' "$*" >&2; }


# --- what upstream asks for -------------------------------------------------

# Every pkg-config module named in utils/gen-*-flags.  Two spellings appear
# there: the `gen-pkgconf-flags <VAR> <module>` helper for the mandatory ones,
# and a bare `pkg-config [opts] <module>` probe for each optional one.  A module
# name may not start with `-`, which is what keeps the `pkg-config --cflags
# "${pc}"` lines inside the helper itself out of the result.
pc_wanted() {
	grep -hoE '(gen-pkgconf-flags[[:space:]]+[A-Z0-9_]+|pkg-config([[:space:]]+--[a-z-]+(=[0-9.]+)?)*)[[:space:]]+[A-Za-z0-9_+][A-Za-z0-9_.+-]*' \
		"$src"/utils/gen-*-flags |
		awk '{ print $NF }' | sort -u
}

# Modules deliberately left out.  Everything else has to resolve.
pc_skipped() {
	case $1 in
	# sd_notify() means nothing in a container, and Alpine only offers
	# libsystemd through elogind, which drags in a session manager.
	libsystemd) ;;
	# Only the fallback branch of the libmariadb probe in gen-common-flags.
	mysqlclient) ;;
	# Sipwise's proprietary EVS accelerator.  Not publicly available; EVS is
	# instead dlopen()ed at runtime from `evs-lib-path`, see codecs.sh.
	codec-chain|libcodec-chain) ;;
	*) return 1 ;;
	esac
}


# --- translating to Alpine --------------------------------------------------

# Ambiguity apk cannot settle on its own goes here.  Everything else is answered
# by `apk search -e pc:<module>` plus the name preference below, which is why
# this table has one entry and should stay that short.
pc_override() {
	case $1 in
	# Both libjwt-dev and libjwt2-dev claim pc:libjwt, and the name
	# preference below would take the former -- but that is libjwt 3, which
	# renamed jwt_new()/jwt_add_grant()/jwt_encode_str() out of existence.
	# rtpengine's lib/oauth.c is still written against the 2.x API, and so is
	# the libjwt-dev that debian/control asks for.
	libjwt) echo libjwt2-dev ;;
	esac
}

pc_package() {
	mod=$1

	forced=$(pc_override "$mod")
	[ -z "$forced" ] || { echo "$forced"; return 0; }

	# shellcheck disable=SC2046 # deliberate word splitting into $@
	set -- $(apk search --quiet --exact "pc:$mod" | sort -u)
	[ $# -gt 0 ] || return 1
	[ $# -gt 1 ] || { echo "$1"; return 0; }

	# Several providers: pc:hiredis is offered by hiredis-dev and by the
	# hiredict fork, pc:spandsp by spandsp-dev and spandsp3-dev.  Prefer the
	# candidate whose name is the module's own.
	base=${mod%%-[0-9]*}
	for want in "$mod-dev" "$base-dev" "lib${base#lib}-dev" "${base#lib}-dev"; do
		for cand; do
			[ "$cand" = "$want" ] || continue
			echo "$cand"
			return 0
		done
	done
	echo "$1"
}

# Build-Depends entries that are not about compiling rtpengine: Debian packaging
# helpers, upstream's perl test suite, the python bindings built only under the
# pysip-lite profile, and the two markdown tools of which only pandoc is ever
# invoked by the makefiles.
deb_ignored() {
	case $1 in
	debhelper*|dh-*|pybuild*|python3|python3-*|discount) ;;
	*-perl|ngcp-*) ;;
	# Same reasoning as pc_skipped.
	libsystemd-dev|systemd|systemd-dev) ;;
	# Provided by the source-built ffmpeg and bcg729; Alpine's would only be
	# dead weight in the build stage.
	libav*-dev|libswresample-dev|libpostproc-dev|libbcg729-dev) ;;
	*) return 1 ;;
	esac
}

# Debian glues SONAME versions and flavours onto package names in ways no rule
# recovers.  Everything else is handled by deb_package's stripping.
deb_override() {
	case $1 in
	libjwt-dev)                  echo libjwt2-dev ;;   # see pc_override
	libssl-dev)                  echo openssl-dev ;;
	libcurl4-*-dev)              echo curl-dev ;;
	default-libmysqlclient-dev)  echo mariadb-connector-c-dev ;;
	libiptc-dev|libxtables-dev)  echo iptables-dev ;;
	esac
}

deb_package() {
	name=$1

	forced=$(deb_override "$name")
	[ -z "$forced" ] || { echo "$forced"; return 0; }

	base=${name%-dev}
	base=${base#lib}
	# libpcap0.8-dev, libglib2.0-dev, zlib1g-dev: Debian carries the SONAME
	# version in the package name, Alpine does not.
	bare=$(printf '%s' "$base" | sed -E 's/[0-9][0-9a-z.]*$//')

	for want in "$name" "$base-dev" "lib$base-dev" "$bare-dev" "lib$bare-dev" "$base" "$bare"; do
		[ -n "$want" ] || continue
		# --exact matches provides too, which is how `pandoc` finds
		# pandoc-cli.  Take apk's answer, not the name we guessed with.
		hit=$(apk search --quiet --exact "$want" | head -n1)
		[ -n "$hit" ] || continue
		echo "$hit"
		return 0
	done
	return 1
}

# Build-Depends, one dependency per line, with version constraints dropped and
# alternatives kept as `a|b`.  An entry restricted to a build profile is taken
# only when every restriction is negated -- `<!pkg.x>` means "built unless x",
# `<pkg.x>` means "only under x" -- which is Debian's own default-profile
# behaviour, and which is what pulls in the whole transcoding dependency set.
deb_wanted() {
	awk '
		/^Build-Depends:/ { in_bd = 1; next }
		in_bd && /^[^ \t]/ { in_bd = 0 }
		in_bd
	' "$src/debian/control" |
	tr ',' '\n' |
	while read -r entry; do
		case $entry in
		*'<'*) case $entry in *'<!'*'>'*) ;; *) continue ;; esac ;;
		esac
		printf '%s\n' "$entry" |
			sed -e 's/([^)]*)//g' -e 's/<[^>]*>//g' \
			    -e 's/[[:space:]]*|[[:space:]]*/|/g' \
			    -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
	done | grep -v '^$' | sort -u
}


# --- resolve ----------------------------------------------------------------

apk update

packages=
unresolved=

say '==> pkg-config modules probed by utils/gen-*-flags'
for mod in $(pc_wanted); do
	if pc_skipped "$mod"; then
		say "    $mod -> skipped on purpose"
	elif pkg-config --exists "$mod"; then
		# Already there, which is how the source-built ffmpeg and bcg729
		# keep Alpine's copies from being pulled in on top of them.
		say "    $mod -> already installed"
	elif pkg=$(pc_package "$mod"); then
		say "    $mod -> $pkg"
		packages="$packages $pkg"
	else
		say "    $mod -> NOTHING PROVIDES IT"
		unresolved="$unresolved $mod"
	fi
done

say '==> Build-Depends from debian/control'
for entry in $(deb_wanted); do
	pkg=
	# `a|b` alternatives: the first one Alpine can satisfy wins.
	for alt in $(printf '%s' "$entry" | tr '|' ' '); do
		deb_ignored "$alt" && { pkg=ignored; break; }
		if pkg=$(deb_package "$alt"); then
			packages="$packages $pkg"
			break
		fi
		pkg=
	done
	case $pkg in
	'')        say "    $entry -> no Alpine equivalent, skipping" ;;
	ignored)   say "    $entry -> not needed to compile" ;;
	*)         say "    $entry -> $pkg" ;;
	esac
done

packages=$(printf '%s\n' $packages | sort -u | tr '\n' ' ')
say "==> apk add$packages"
# shellcheck disable=SC2086 # deliberate word splitting of the package list
apk add --no-cache $packages


# --- verify -----------------------------------------------------------------
#
# The install above is a best effort; this is the gate.  Anything upstream
# probes for has to be present now, because a missing optional module does not
# fail the compile -- it produces a daemon that silently cannot transcode.

missing=
for mod in $(pc_wanted); do
	pc_skipped "$mod" && continue
	pkg-config --exists "$mod" || missing="$missing $mod"
done

if [ -n "$missing$unresolved" ]; then
	say
	say 'Unsatisfied pkg-config modules:'
	for mod in $(printf '%s\n' $missing $unresolved | sort -u); do say "  $mod"; done
	say
	say 'rtpengine probes for these in utils/gen-*-flags.  If Alpine packages'
	say 'one under a name apk cannot map from `pc:<module>`, add it to'
	say 'pc_override above; if Alpine does not package it at all, it has to be'
	say 'built from source in the media stage like bcg729 and libilbc are.'
	exit 1
fi

say '==> every probed module resolved'
