# fpga-eth-core: payload-agnostic 10/100 Ethernet MAC + IPv4/UDP for 7-series FPGAs.
OSS := $(HOME)/.local/opt/oss-cad-suite/bin
export PATH := $(PATH):$(OSS)
PY ?= python3
RTL := $(wildcard rtl/*.sv)
# Example design: Xilinx primitives come from tb/models/ stand-ins for lint and sim only.
EX_RX := $(wildcard examples/rx_stats/*.sv examples/rx_stats/xilinx/*.sv) $(wildcard tb/models/*.sv)

.PHONY: lint formal sim ci example clean

lint:
	@for f in $(RTL); do \
	  verilator --lint-only -Wall --assert $(RTL) --top-module $$(basename $$f .sv) || exit 1; \
	done
	verilator --lint-only -Wall --assert $(RTL) $(EX_RX) --top-module rx_stats_top

formal:
	cd formal && sby -f async_fifo.sby

sim:
	$(PY) tb/run.py

ci: lint formal sim

# Vivado batch build of examples/rx_stats (local only; needs vivado-env). Reports land in
# docs/reports/rx_stats/; no bitstream unless timing is met and CDC is clean.
example:
	vivado -mode batch -nojournal -log build/vivado_rx_stats.log -source syn/build_rx_stats.tcl

clean:
	rm -rf build formal/async_fifo_prove formal/async_fifo_cover
