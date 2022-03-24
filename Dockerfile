FROM erlang:24
ENV DEBIAN_FRONTEND noninteractive

RUN apt update
RUN apt-get install -y -q \
        build-essential \
        bison \
        flex \
        git \
        gzip \
        autotools-dev \
        automake \
        libtool \
        pkg-config \
        cmake \
        libsodium-dev \
        iproute2

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"
RUN rustup update

WORKDIR /opt/router

ARG BUILD_NET=mainnet

ADD rebar3 rebar3
ADD rebar.config rebar.config
ADD rebar.lock rebar.lock
ADD config/grpc_client_gen.config config/grpc_client_gen.config
ADD config/grpc_server_gen.config config/grpc_server_gen.config
RUN ./rebar3 get-deps
RUN ./rebar3 as ${BUILD_NET} compile

ADD Makefile Makefile
ADD c_src/ c_src/
ADD include/ include/
ADD src/ src/
ADD scripts/ scripts/
RUN make

ADD config/ config/
ADD priv/genesis.${BUILD_NET} priv/genesis
RUN ./rebar3 as ${BUILD_NET} release

ENV PATH=$PATH:_build/${BUILD_NET}/rel/router/bin
RUN ln -s /opt/router/_build/${BUILD_NET}/rel /opt/router/_build/default/rel
RUN ln -s /opt/router/_build/default/rel/router/bin/router /opt/router-exec

ARG ROUTER_VERSION
ENV ROUTER_VERSION=${ROUTER_VERSION:-unknown}
RUN echo $ROUTER_VERSION > router.version

CMD ["make", "run"]
