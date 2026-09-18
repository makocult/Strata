#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
sources=()
for source in Sources/Strata/*.swift; do
    [[ "$source" == */StrataApp.swift ]] || sources+=("$source")
done
for test in Smoke CanvasSmoke NavigationSmoke MaterialStoreSmoke MaterialCanvasSmoke AISmoke InteractionSmoke; do
    swiftc -o ".build/$test" "${sources[@]}" "Tests/$test.swift"
    ".build/$test"
done
