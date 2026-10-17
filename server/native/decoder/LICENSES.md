# Licenses in the decoder sandbox artifact

Recorded per DESIGN.md section 3 (no GPL-family software in any artifact).

| Component | License | Notes |
| --- | --- | --- |
| decoder, launcher | Apache-2.0 | This directory |
| musl libc (static) | MIT | |
| libjpeg-turbo (static) | IJG AND BSD-3-Clause AND Zlib | |
| libpng (static) | libpng-2.0 | PNG Reference Library License v2 |
| zlib (static) | Zlib | |
| minijail0 and libminijail (static, in the launcher) | BSD-3-Clause | Pinned commit `f4882a440f6d6eab7f35190e06bc16257ef3dcae` |
| libcap (static) | BSD-3-Clause OR GPL-2.0-only | **BSD-3-Clause elected** |
| compiler-rt builtins, crtbegin/crtend | Apache-2.0 WITH LLVM-exception | Replaces libgcc |

The Alpine build image (BusyBox, clang, and ImageMagick in the test stage
only) is development tooling and never enters the artifact.
