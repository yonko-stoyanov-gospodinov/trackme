#!/bin/sh
# Compiles the engine with its tests and runs them. Needs only a Swift compiler.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
"${SWIFTC:-swiftc}" -swift-version 5 -O -o build/core-tests sources/core/*.swift tests/main.swift
./build/core-tests
