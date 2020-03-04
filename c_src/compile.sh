#!/bin/sh

VERSION="e4c02439932dbcdfcd65199a2a361d90ccef99e5"


if [ ! -d c_src/LoRaMac-node ]; then
    git clone https://github.com/helium/LoRaMac-node.git c_src/LoRaMac-node
fi

cd c_src/LoRaMac-node

CURRENT_VERSION=`git rev-parse HEAD`

if [ ! "$VERSION" = "$CURRENT_VERSION" ]; then
    git clean -ddxxff
    git fetch
    git checkout $VERSION
fi


if [ ! -d build ]; then
    cmake -H. -Bbuild -DAPPLICATION="LoRaMac" -DSUB_PROJECT="classA" -DBOARD="Simul" -DRADIO="radio-simul"
fi
make -C build -j
cp build/src/apps/LoRaMac/LoRaMac-classA ../../priv
