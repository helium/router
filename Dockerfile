FROM erlang:22 AS erlang
FROM rust:1.43.1 AS rust

WORKDIR /opt/router

COPY --from=rust /usr/local/rustup /usr/local/rustup
COPY --from=rust /usr/local/cargo /usr/local/cargo

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

COPY --from=erlang /usr/local/lib/erlang /usr/local/lib/erlang
ENV PATH=/usr/local/lib/erlang/bin:$PATH

ENV LD_LIBRARY_PATH /usr/local/lib
RUN apt-get update
RUN apt-get install -y autoconf automake libtool flex bison libgmp-dev cmake build-essential emacs-nox libssl-dev

RUN git clone -b stable https://github.com/jedisct1/libsodium.git
RUN cd libsodium && ./configure --prefix=/usr && make check && make install && cd ..

ADD rebar3 rebar3
ADD rebar.config rebar.config
ADD rebar.lock rebar.lock
ADD config/grpc_client_gen.config config/grpc_client_gen.config
ADD config/grpc_server_gen.config config/grpc_server_gen.config
RUN ./rebar3 get-deps
RUN ./rebar3 compile

ADD Makefile Makefile
ADD c_src/ c_src/
ADD include/ include/
ADD src/ src/
ADD scripts/ scripts/
RUN make

ADD config/ config/
ADD priv/ priv/
RUN make rel

CMD ["make", "run"]
