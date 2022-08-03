FROM amd64/debian:testing-slim

ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && apt-get install -y procps && rm -rf /var/lib/apt/lists/*

# See ../../Make-deb-package.mk for short name of .deb being a
# hard-link (ln) to ${DEBIAN_PACKAGE_NAME}_${REVISION}_${DEB_ARCH}.deb
COPY router.deb .

RUN dpkg -i router.deb
RUN dpkg --audit

WORKDIR /opt/router/router

CMD ["/opt/router/router/bin/router", "versions"]
