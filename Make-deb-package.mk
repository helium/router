# FIXME -- DO NOT MERGE to master yet!!!
# FIXME replicate ../helium-packet-router/Make-deb-package.mk
# i.e., copy the .mk file that's invoked here, and set vars accordingly.

# Usage:

# make -f Make-deb-package.mk
# make -f Make-deb-package.mk clean

NAME=router

# TODO decouple mainnet,testnet from .deb package.
ifdef BUILD_NET
GENESIS_PATH := priv/genesis.${BUILD_NET}
endif
EXTRA_PATHS := scripts/ config/

all:
	NAME=${NAME} SHORT_NAME=${NAME} \
	  GENESIS_PATH="${GENESIS_PATH}" EXTRA_PATHS="${EXTRA_PATHS}" \
	  make -f ../helium-packet-router/Make-deb-package.mk

%:
	NAME=${NAME} SHORT_NAME=${NAME} \
	  GENESIS_PATH="${GENESIS_PATH}" EXTRA_PATHS="${EXTRA_PATHS}" \
	  make -f ../helium-packet-router/Make-deb-package.mk $@
