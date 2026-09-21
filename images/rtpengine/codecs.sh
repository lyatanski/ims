#!/bin/sh
#
# Assert rtpengine's codec matrix.
#
# `rtpengine --codecs` prints one line per codec it knows about, graded by what
# the libraries it was linked against can actually do.  This compares that
# against the table below and fails the build on any regression.
#
# It is worth gating on because rtpengine's transcoding libraries are all
# optional to its build system: drop bcg729 and G.729 silently becomes "not
# supported"; build ffmpeg without libvo-amrwbenc and AMR-WB silently drops to
# "supported for decoding only".  Either way the compile succeeds and the image
# looks fine until a call needs transcoding.  A codec upstream adds later shows
# up here as unknown, and is only an error if it arrives unsupported -- which is
# the signal that it needs a library this image does not carry yet.
#
# Usage: codecs.sh <path to rtpengine>

set -eu

rtpengine=${1:?usage: codecs.sh <path to rtpengine>}

# `lacks RTP definition` below means the codec transcodes but has no static
# payload type or fmtp default, so it is usable only when the SDP names it
# explicitly -- a real, if lesser, level of support.

# The floor.  Anything below its entry here fails the build.
#
# The decode-only entries are not shortcomings of this image: no encoder exists
# for EVRC, QCELP or ATRAC in ffmpeg or anywhere else that could be shipped.
#
# H264, VP8 and VP9 are decode-only for a different reason, and a deliberate
# one.  Upstream grew video transcoding in the MT#65420 series, and ffmpeg's
# native decoders for all three come along for free -- but every encoder is an
# external library (libx264, libvpx), and this is an IMS audio media relay:
# neither compose.yml nor the chart offers a video stream to transcode.  Adding
# x264-dev and libvpx-dev to the media stage promotes all three to `fully
# supported (video)` if that ever changes.
#
# Neither are the five that "lack RTP definition".  MP3, PCM-U8, AC-3, E-AC-3
# and Vorbis transcode both ways here; they simply have no static payload type
# or default clock rate to fall back on, so an SDP has to name them.  No library
# changes that -- it is a property of the codecs.
#
# EVS is absent by design.  rtpengine dlopen()s it at runtime from the path
# given by `evs-lib-path`, from a build of the 3GPP TS 26.442 reference source,
# which is licensed per-user and cannot travel inside an image.  Mount one in
# and it works without rebuilding this.
expected() {
	cat <<-'TABLE'
	AMR                fully supported (audio)
	AMR-WB             fully supported (audio)
	ATRAC-X            supported for decoding only
	ATRAC3             supported for decoding only
	CN                 fully supported (audio)
	EVRC               supported for decoding only
	EVRC0              supported for decoding only
	EVRC1              supported for decoding only
	EVS                not supported
	G722               fully supported (audio)
	G723               fully supported (audio)
	G726-16            fully supported (audio)
	G726-24            fully supported (audio)
	G726-32            fully supported (audio)
	G726-40            fully supported (audio)
	G729               fully supported (audio)
	G729a              fully supported (audio)
	GSM                fully supported (audio)
	H264               supported for decoding only
	L16                fully supported (audio)
	MP3                codec supported but lacks RTP definition
	PCM-U8             codec supported but lacks RTP definition
	PCMA               fully supported (audio)
	PCMU               fully supported (audio)
	QCELP              supported for decoding only
	VP8                supported for decoding only
	VP9                supported for decoding only
	X-L16              fully supported (audio)
	ac3                codec supported but lacks RTP definition
	eac3               codec supported but lacks RTP definition
	iLBC               fully supported (audio)
	opus               fully supported (audio)
	red                fully supported (audio)
	speex              fully supported (audio)
	telephone-event    fully supported (audio)
	vorbis             codec supported but lacks RTP definition
	TABLE
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

expected | sed -e 's/[[:space:]][[:space:]]*/\t/' > "$work/want"
"$rtpengine" --codecs | sed -e 's/^[[:space:]]*//' -e 's/:[[:space:]]*/\t/' > "$work/have"

sed 's/^/    /' "$work/have"

awk -F'\t' '
	function grade(s) {
		if (s == "fully supported (audio)")                  return 3
		if (s == "fully supported (video)")                  return 3
		if (s == "fully supported")                          return 3
		if (s == "codec supported but lacks RTP definition") return 2
		if (s == "supported for encoding only")              return 1
		if (s == "supported for decoding only")              return 1
		return 0
	}
	NR == FNR { want[$1] = $2; next }
	{
		have[$1] = $2
		if (!($1 in want)) {
			# Upstream grew a codec since this table was written.
			if (grade($2) < 2) {
				printf "REGRESSED %s is \"%s\" -- it needs a library this image does not carry\n", $1, $2
				bad++
			} else
				printf "NEW       %s is \"%s\" -- add it to the table in codecs.sh\n", $1, $2
		}
		else if (grade($2) < grade(want[$1])) {
			printf "REGRESSED %s -- expected \"%s\", got \"%s\"\n", $1, want[$1], $2
			bad++
		}
	}
	END {
		for (c in want)
			if (!(c in have)) {
				printf "MISSING   %s -- upstream renamed or dropped it\n", c
				bad++
			}
		exit bad ? 1 : 0
	}
' "$work/want" "$work/have" >&2 || exit 1

echo '==> codec matrix as expected'
