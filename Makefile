.PHONY: fmt build test

fmt:
	forge fmt
	@for f in $$(find src -name '*.sol'); do shafu "$$f" --write; done
	@echo "Formatted all .sol files with forge fmt + shafu"

build:
	forge build

test:
	forge test
