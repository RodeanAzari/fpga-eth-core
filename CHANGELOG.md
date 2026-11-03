# Changelog

Releases are tagged only after their gate test passes (see `~/fpga-coord/dependencies.toml`).

## Unreleased
- `async_fifo`: dual-clock Gray-pointer FIFO, AXI-Stream on both sides, first-word-fall-through
  read, write-side and read-side occupancy outputs.
  - Formal (`make formal`): no overflow or underflow, Gray encoding, synchronizer-chain
    monotonicity, data integrity of an arbitrary tagged word. k-induction PASS at depth 24
    on a depth-4 instance; cover of full and drained-empty reached.
  - Three planted bugs each fail the proof: write allowed at full, binary (non-Gray)
    read pointer, read from the wrong address.
  - cocotb (`make sim`): 3 clock-ratio and backpressure scenarios at depth 16 and 2048,
    3,000 random words each, in order, full reached exactly at DEPTH.
