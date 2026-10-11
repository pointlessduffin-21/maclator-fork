#!/bin/bash
# Builds the Maclator Metal bridge:
#   libmclbridge.dylib   x86-64 host side (loaded by maclator on first GPU call)
#   libmclmetal.dylib    arm64 + arm64e guest shim (injected with DYLD_INSERT_LIBRARIES; arm64e guests refuse an arm64-only dylib)
#   libmclloop.dylib     arm64 shim + bridge in one dylib for native testing on an Apple Silicon Mac
#   metaltri (arm64)     guest smoke test
set -e
cd "$(dirname "$0")"
OUT=${OUT:-out}
mkdir -p $OUT
clang -arch x86_64 -dynamiclib -fobjc-arc -O2 -framework Foundation -framework Metal -framework IOSurface \
  -install_name @rpath/libmclbridge.dylib mclbridge.m -o $OUT/libmclbridge.dylib
clang -arch arm64 -arch arm64e -dynamiclib -fno-objc-arc -O2 -framework Foundation -framework Metal -framework IOSurface \
  -install_name @rpath/libmclmetal.dylib mclmetal.m -o $OUT/libmclmetal.dylib
codesign -f -s - $OUT/libmclbridge.dylib $OUT/libmclmetal.dylib
if [ "$(uname -m)" = arm64 ]; then
  clang -arch arm64 -c -fobjc-arc -O2 -DMCL_LOOPBACK mclbridge.m -o $OUT/bridge_loop.o
  clang -arch arm64 -c -fno-objc-arc -O2 -DMCL_LOOPBACK mclmetal.m -o $OUT/shim_loop.o
  clang -arch arm64 -dynamiclib -framework Foundation -framework Metal -framework QuartzCore \
    -install_name @rpath/libmclloop.dylib $OUT/bridge_loop.o $OUT/shim_loop.o -o $OUT/libmclloop.dylib
  codesign -f -s - $OUT/libmclloop.dylib
  if [ -f ../tests/guest/metaltri.m ]; then
    clang -arch arm64 -fobjc-arc -O1 -DMCL_LOOPBACK -Wno-deprecated-declarations -Wl,-rpath,@executable_path -framework Foundation -framework Metal ../tests/guest/metaltri.m $OUT/libmclloop.dylib -o $OUT/metaltri_loop
    codesign -f -s - $OUT/metaltri_loop
  fi
fi
# The metaltri smoke test is optional (not needed by maclator itself).
if [ -f ../tests/guest/metaltri.m ]; then
  clang -arch arm64 -fobjc-arc -O1 -Wno-deprecated-declarations -Wno-gnu-folding-constant -framework Foundation -framework Metal ../tests/guest/metaltri.m -o $OUT/metaltri
  codesign -f -s - $OUT/metaltri
fi
echo built
