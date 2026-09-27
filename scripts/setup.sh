#!/usr/bin/env bash

# Sets up a linux or windows environment to build ellipse

mkdir -p build

NIM_VERSION="2.2.12"
NIMONY_VERSION="0.6.2"

pushd build > /dev/null

if [ ! -d "nim" ]; then
    curl -L -o nim.tar.xz https://nim-lang.org/download/nim-$NIM_VERSION-linux_x64.tar.xz
    tar -xf ./nim.tar.xz
    mv "nim-$NIM_VERSION" nim
fi

if [ ! -d "nimony" ]; then
    curl -L -o nimony.tar.gz "https://github.com/nim-lang/nimony/archive/refs/tags/v$NIMONY_VERSION.tar.gz"
    tar -xf ./nimony.tar.gz
    mv "nimony-$NIMONY_VERSION" nimony
fi

pushd nimony > /dev/null
git init
../nim/bin/nim c -r src/hastur/hastur build all
popd > /dev/null

popd > /dev/null
