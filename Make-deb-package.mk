# FIXME -- DO NOT MERGE to master yet!!!
# FIXME replicate ../helium-packet-router/Make-deb-package.mk
# i.e., copy the .mk file that's invoked here, and set vars accordingly.

# Usage:

# make -f Make-deb-package.mk
# make -f Make-deb-package.mk clean

NAME=router

all:
	NAME=${NAME} SHORT_NAME=${NAME} \
	  make -f ../helium-packet-router/Make-deb-package.mk

%:
	NAME=${NAME} SHORT_NAME=${NAME} \
	  make -f ../helium-packet-router/Make-deb-package.mk $@
