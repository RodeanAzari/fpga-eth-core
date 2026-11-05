# fpga-eth-core: payload-agnostic 10/100 Ethernet MAC + IPv4/UDP for 7-series FPGAs.
OSS := $(HOME)/.local/opt/oss-cad-suite/bin
export PATH := $(PATH):$(OSS)
PY ?= python3
RTL := $(wildcard rtl/*.sv)
# Example design: Xilinx primitives come from tb/models/ stand-ins for lint and sim only.
EX_RX := $(wildcard examples/rx_stats/*.sv examples/rx_stats/xilinx/*.sv) $(wildcard tb/models/*.sv)
EX_ECHO := $(filter-out examples/rx_stats/rx_stats_top.sv,$(EX_RX)) examples/udp_echo/udp_echo_top.sv

.PHONY: lint formal sim host host-test ci example example-echo clean

lint:
	@for f in $(RTL); do \
	  verilator --lint-only -Wall --assert $(RTL) --top-module $$(basename $$f .sv) || exit 1; \
	done
	verilator --lint-only -Wall --assert $(RTL) $(EX_RX) --top-module rx_stats_top
	verilator --lint-only -Wall --assert $(RTL) $(EX_ECHO) --top-module udp_echo_top

formal:
	cd formal && sby -f async_fifo.sby

sim:
	$(PY) tb/run.py

# Host tools (C++20). host-test sends over loopback and checks every datagram.
host:
	cmake -S host -B build/host -DCMAKE_BUILD_TYPE=Release
	cmake --build build/host

host-test: host
	$(PY) host/test_udp_seq_send.py build/host/udp_seq_send
	$(PY) host/test_udp_echo_check.py build/host/udp_echo_check

ci: lint formal sim host-test

# Vivado batch builds of the example designs (local only; needs vivado-env). Reports land
# in docs/reports/<example>/; no bitstream unless timing is met and CDC is clean.
example:
	vivado -mode batch -nojournal -log build/vivado_rx_stats.log -source syn/build_example.tcl -tclargs rx_stats

example-echo:
	vivado -mode batch -nojournal -log build/vivado_udp_echo.log -source syn/build_example.tcl -tclargs udp_echo

clean:
	rm -rf build formal/async_fifo_prove formal/async_fifo_cover
