.PHONY: test bench

test:
	nvim --headless --clean --cmd 'set rtp+=.' -l tests/run.lua

bench:
	nvim --headless --clean -l bench/run.lua $(SCENARIOS)
