FROM erlang:22

WORKDIR /opt/router

ENV LD_LIBRARY_PATH /usr/local/lib
RUN apt-get update
RUN apt-get install -y autoconf automake libtool flex bison libgmp-dev cmake libsodium-dev cmake build-essential emacs libssl-dev

RUN git clone -b stable https://github.com/jedisct1/libsodium.git
RUN cd libsodium && ./configure --prefix=/usr && make check && make install && cd ..

ADD Makefile Makefile
ADD rebar3 rebar3
ADD rebar.config rebar.config
ADD rebar.lock rebar.lock
RUN ./rebar3 get-deps
RUN make

ADD include/ include/
ADD src/ src/
ADD test/ test/
RUN make

ADD config/vm.args config/vm.args
ADD config/sys.config.src config/sys.config.src
RUN ./rebar3 release

CMD ["_build/default/rel/router/bin/router", "foreground"]