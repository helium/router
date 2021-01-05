.PHONY: compile clean test rel run

REBAR=./rebar3

compile:
	$(REBAR) compile
	$(REBAR) format

clean:
	git clean -dXfffffffffff

test:
	$(REBAR) fmt --verbose --check rebar.config
	$(REBAR) fmt --verbose --check "{src,include,test}/**/*.{hrl,erl,app.src}"
	$(REBAR) fmt --verbose --check "config/sys.{config,config.src}"
	$(REBAR) xref
	$(REBAR) dialyzer
	$(REBAR) eunit
	$(REBAR) ct

rel:
	$(REBAR) release

run:
	_build/default/rel/router/bin/router foreground

# Pass all unknown targets straight to rebar3 (e.g. `make dialyzer`)
%:
	$(REBAR) $@
