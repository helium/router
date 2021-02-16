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

for REGION in US915 EU868 AS923 CN470; do
    if [ ! -d build_$REGION ]; then
        cmake -H. -Bbuild_$REGION -DREGION_$REGION=1 -DACTIVE_REGION=LORAMAC_REGION_$REGION -DAPPLICATION="LoRaMac" -DSUB_PROJECT="classA" -DBOARD="Simul" -DRADIO="radio-simul"
    fi
    make -C build_$REGION -j
    cp build_$REGION/src/apps/LoRaMac/LoRaMac-classA ../../priv/LoRaMac-classA_$REGION
done
