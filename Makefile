.PHONY: compile test typecheck ci

REBAR=./rebar3
ifeq ($(BUILDKITE), true)
  # get branch name and replace any forward slashes it may contain
  CIBRANCH=$(subst /,-,$(BUILDKITE_BRANCH))
else
  CIBRANCH=$(shell git rev-parse --abbrev-ref HEAD | sed 's/\//-/')
endif

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
