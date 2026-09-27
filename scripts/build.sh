#!/usr/bin/env bash
# Build with swiftc directly, in the same two modules Package.swift describes.
#
# There is a Package.swift and it is correct, but SwiftPM cannot run on a
# machine with only Command Line Tools installed and a version skew between
# libPackageDescription.dylib and the Swift compiler — the manifest fails to
# link with an undefined PackageDescription.Package symbol. Rather than make the
# whole project depend on a working Xcode install, the primary build is plain
# swiftc, which needs nothing but the compiler.
#
# The library is built first as a static archive with its own module, and the
# executable is compiled against that module. Compiling everything as one
# module would hide access-control mistakes that SwiftPM would then reject.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT=${OUT:-bin}
KIT=${KIT:-$OUT/.kit}
FLAGS=(-swift-version 6 -O)
mkdir -p "$OUT" "$KIT"

echo "building into $OUT/"
swiftc "${FLAGS[@]}" -parse-as-library -emit-library -static -emit-module \
    -module-name MacControlKit -o "$KIT/libMacControlKit.a" \
    Sources/MacControlKit/*.swift
echo "  MacControlKit"
swiftc "${FLAGS[@]}" -I "$KIT" -L "$KIT" -lMacControlKit -o "$OUT/macctl" \
    Sources/macctl/main.swift
echo "  macctl"
echo "done"
