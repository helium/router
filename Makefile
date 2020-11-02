.PHONY: compile test typecheck ci

REBAR=./rebar3
ifeq ($(BUILDKITE), true)
  # get branch name and replace any forward slashes it may contain
  CIBRANCH=$(subst /,-,$(BUILDKITE_BRANCH))
else
  CIBRANCH=$(shell git rev-parse --abbrev-ref HEAD | sed 's/\//-/')
endif

compile:
	$(REBAR) format && $(REBAR) compile

clean:
	$(REBAR) clean

test: compile
	$(REBAR) as test do xref, eunit, ct && $(REBAR) dialyzer

ci:
	$(REBAR) dialyzer && ($(REBAR) as test do xref, eunit, ct || (mkdir -p artifacts; tar --exclude='./_build/test/lib' --exclude='./_build/test/plugins' -czf artifacts/$(CIBRANCH).tar.gz _build/test; false))

typecheck:
	$(REBAR) dialyzer

cover:
	$(REBAR) cover

rel:
	$(REBAR) release

run:
	_build/default/rel/router/bin/router foreground
