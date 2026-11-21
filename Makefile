ODIN     ?= odin
SITE_URL ?= https://narcisdedu.com
SERVER   ?= $(server_ip)

# Served at /version: GITHUB_SHA in CI, otherwise HEAD, plus -dirty with uncommitted changes
GIT_SHA ?= $(or $(GITHUB_SHA),$(shell git rev-parse HEAD)$(shell git status --porcelain | grep -q . && echo -dirty))

# Build modes, for build and run:
#   make build          Odin's default optimisation (-o:minimal): quick to compile
#   make build release  -o:speed: what the server runs
#   make build debug    -debug: debugger info, no optimisation, leak report, Debug logs
MODE := $(filter release debug,$(MAKECMDGOALS))
ifneq ($(word 2,$(MODE)),)
$(error pick one of release or debug, not both)
endif
FLAGS_release := -o:speed
FLAGS_debug   := -debug

.PHONY: build run test clean live logs release debug

# The single quotes keep GIT_SHA a string: Odin reads an all-digit -define value as a number
build:
	@mkdir -p build
	$(ODIN) build cmd/web -out:build/site $(FLAGS_$(MODE)) "-define:GIT_SHA='$(GIT_SHA)'"

run: build
	./build/site

test:
	@mkdir -p build
	$(ODIN) test cmd/web -out:build/test-web -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
	$(ODIN) test internal/dotenv -out:build/test-dotenv -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
	$(ODIN) test internal/accesslog -out:build/test-accesslog -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

release debug:
	@$(if $(filter build run,$(MAKECMDGOALS)),:,echo "use it with build or run, e.g. make build $@")

clean:
	rm -rf build

# After a push: is the live site on HEAD?
live:
	@live_sha=$$(curl -fsS --max-time 10 $(SITE_URL)/version) || exit 1; \
	head_sha=$$(git rev-parse HEAD); \
	echo "live: $$live_sha"; \
	echo "HEAD: $$head_sha"; \
	if [ "$$live_sha" = "$$head_sha" ]; then echo "match"; else echo "different" >&2; exit 1; fi

logs:
	@[ -n "$(SERVER)" ] || { echo "no server address: export server_ip, or run: make logs SERVER=<address>" >&2; exit 1; }
	ssh -t root@$(SERVER) journalctl -u site -n 50 -f
