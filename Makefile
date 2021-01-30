.PHONY: compile clean test rel run grpc docker-build docker-test docker-run
grpc_services_directory=src/grpc/autogen

REBAR=./rebar3

compile: | $(grpc_services_directory)
	$(REBAR) compile
	$(REBAR) format

clean:
	git clean -dXfffffffffff

test: | $(grpc_services_directory)
	$(REBAR) fmt --verbose --check rebar.config
	$(REBAR) fmt --verbose --check "{src,include,test}/**/*.{hrl,erl,app.src}" --exclude-files "src/grpc/autogen/**/*"
	$(REBAR) fmt --verbose --check "config/{test,sys}.{config,config.src}"
	$(REBAR) xref
	$(REBAR) eunit
	$(REBAR) ct
	$(REBAR) dialyzer

rel: | $(grpc_services_directory)
	$(REBAR) release

run: | $(grpc_services_directory)
	_build/default/rel/router/bin/router foreground

docker-build:
	docker build -f Dockerfile-local --rm -t quay.io/team-helium/router:local .

docker-test:
	docker run --rm -it --init --name=helium_router_test quay.io/team-helium/router:local make test

docker-run: 
	docker run --rm -it --init --env-file=.env --network=host --volume=data:/var/data --name=helium_router quay.io/team-helium/router:local

grpc:
	REBAR_CONFIG="config/grpc_server_gen.config" $(REBAR) grpc gen
	REBAR_CONFIG="config/grpc_client_gen.config" $(REBAR) grpc gen

$(grpc_services_directory):
	@echo "grpc service directory $(directory) does not exist, generating services"
	$(REBAR) get-deps
	$(MAKE) grpc

# Pass all unknown targets straight to rebar3 (e.g. `make dialyzer`)
%:
	$(REBAR) $@
