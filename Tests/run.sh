#!/bin/sh
# Compiles the engine with its tests and runs them. Needs only a Swift compiler.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
"${SWIFTC:-swiftc}" -swift-version 5 -O -o build/core-tests Sources/Core/*.swift Tests/main.swift
./build/core-tests
