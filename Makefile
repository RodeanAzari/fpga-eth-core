# fpga-eth-core: payload-agnostic 10/100 Ethernet MAC + IPv4/UDP for 7-series FPGAs.
OSS := $(HOME)/.local/opt/oss-cad-suite/bin
export PATH := $(PATH):$(OSS)
PY ?= python3
RTL := $(wildcard rtl/*.sv)

.PHONY: lint formal sim ci clean

lint:
	@for f in $(RTL); do \
	  verilator --lint-only -Wall --assert $(RTL) --top-module $$(basename $$f .sv) || exit 1; \
	done

formal:
	cd formal && sby -f async_fifo.sby

sim:
	$(PY) tb/run.py

ci: lint formal sim

clean:
	rm -rf build formal/async_fifo_prove formal/async_fifo_cover
