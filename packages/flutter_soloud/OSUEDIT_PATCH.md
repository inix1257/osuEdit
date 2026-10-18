# osuEdit patch of flutter_soloud 5.1.6

Copied from pub.dev `flutter_soloud-5.1.6` (without `example/`, `img/`, `test/`,
`skills/`; `.dart_tool/flutter_soloud/xiph/prebuild/` kept so the build hook
needs no download) and patched in one place:

`src/soloud/src/core/soloud.cpp`, both resample loops ("avoid reading past the
current buffer"): the check now tests the last sample written,
`(writesamples - 1) * step_fixed + mSrcOffset`, instead of the position after
it.

**Bug:** the old check always removed one output sample per 512-sample source
block; on the next block `mSrcOffset < 512` was then "cropped to zero",
skipping `step * frac(512 / step)` source samples per block. The voice played
that much fast while `getPosition()` (`mStreamPosition` = buffer time x speed)
kept nominal time. With the mixer at 44.1 kHz: 0.75x / 1.5x of a 44.1 kHz
file +0.098 % (1/1024), a 48 kHz file at 1x +0.085 % (~51 ms per minute);
0.25x / 0.5x / 1x of 44.1 kHz files were exact (512 / step is an integer).
Measured on a phone by `integration_test/stable_compensation_device_test.dart`.

To update flutter_soloud: copy the new version here, re-apply the patch (or
drop it if upstream fixed the check) and re-run that device test.
