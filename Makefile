.PHONY: compile clean test rel run docker-build docker-test docker-run

REBAR=./rebar3

compile:
	$(REBAR) compile
	$(REBAR) format

clean:
	git clean -dXfffffffffff

test:
	$(REBAR) fmt --verbose --check rebar.config
	$(REBAR) fmt --verbose --check "{src,include,test}/**/*.{hrl,erl,app.src}"
	$(REBAR) fmt --verbose --check "config/{test,sys}.{config,config.src}"
	$(REBAR) xref
	$(REBAR) eunit
	$(REBAR) ct
	$(REBAR) dialyzer

rel:
	$(REBAR) release

run:
	_build/default/rel/router/bin/router foreground

docker-build:
	docker-compose -f docker-compose-local.yaml build --force-rm

docker-test:
	docker-compose -f docker-compose-local.yaml build --force-rm
	docker run --rm helium/router:local make test

docker-run:
	docker-compose -f docker-compose-local.yaml build --force-rm
	docker-compose -f docker-compose-local.yaml down
	docker-compose -f docker-compose-local.yaml up -d
	tail -F data/log/router.log

# Pass all unknown targets straight to rebar3 (e.g. `make dialyzer`)
%:
	$(REBAR) $@
