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

# This will run all ct exepct the lora suite that for now cannot be ran on MacOS
test-mac: | $(grpc_services_directory)
	$(REBAR) fmt --verbose --check rebar.config
	$(REBAR) fmt --verbose --check "{src,include,test}/**/*.{hrl,erl,app.src}" --exclude-files "src/grpc/autogen/**/*"
	$(REBAR) fmt --verbose --check "config/{test,sys}.{config,config.src}"
	$(REBAR) xref
	$(REBAR) eunit
	$(REBAR) ct --suite=router_SUITE,router_channel_aws_SUITE,router_channel_azure_SUITE,router_channel_console_SUITE,router_channel_http_SUITE,router_channel_mqtt_SUITE,router_channel_no_channel_SUITE,router_console_api_SUITE,router_console_dc_tracker_SUITE,router_data_SUITE,router_decoder_SUITE,router_decoder_custom_sup_SUITE,router_decoder_custom_worker_SUITE,router_device_channels_worker_SUITE,router_device_devaddr_SUITE,router_device_routing_SUITE,router_device_worker_SUITE,router_discovery_SUITE,router_downlink_SUITE,router_grpc_SUITE,router_metrics_SUITE,router_sc_worker_SUITE,router_v8_SUITE,router_xor_filter_SUITE
	$(REBAR) dialyzer

rel: | $(grpc_services_directory)
	$(REBAR) release

run: | $(grpc_services_directory)
	_build/default/rel/router/bin/router foreground

docker-build:
	docker build -f Dockerfile-local --force-rm -t quay.io/team-helium/router:local .

docker-test:
	docker run --rm -it --init --name=helium_router_test quay.io/team-helium/router:local make test

docker-test-mac:
	docker run --rm -it --init --name=helium_router_test quay.io/team-helium/router:local make test-mac

docker-run: 
	docker run --rm -it --init --env-file=.env --network=host --volume=data:/var/data --name=helium_router quay.io/team-helium/router:local

docker-exec: 
	docker exec -it helium_router _build/default/rel/router/bin/router remote_console

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
