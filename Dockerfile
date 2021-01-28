FROM heliumsystems/builder-erlang:latest

WORKDIR /opt/router

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
