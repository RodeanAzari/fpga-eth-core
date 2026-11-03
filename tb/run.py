"""Build and run the cocotb tests with Verilator: python tb/run.py [test_module ...]"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parent.parent

# test module -> (toplevel, sources, parameter sets)
TESTS = {
    "test_async_fifo": (
        "async_fifo",
        ["rtl/async_fifo.sv"],
        [{"DATA_W": 8, "ADDR_W": 4}, {"DATA_W": 8, "ADDR_W": 11}],
    ),
}


def main(names: list[str]) -> int:
    failed = 0
    for name in names or list(TESTS):
        top, srcs, param_sets = TESTS[name]
        for params in param_sets:
            tag = "_".join(f"{k}{v}" for k, v in params.items())
            build_dir = ROOT / "build" / "sim" / f"{name}_{tag}"
            runner = get_runner("verilator")
            runner.build(
                sources=[ROOT / s for s in srcs],
                hdl_toplevel=top,
                parameters=params,
                build_args=["--assert", "-Wall", "-Wno-fatal", "--timing"],
                build_dir=build_dir,
                always=True,
            )
            os.environ.update({k: str(v) for k, v in params.items()})
            results = runner.test(
                hdl_toplevel=top,
                test_module=name,
                test_dir=ROOT / "tb",
                build_dir=build_dir,
            )
            from cocotb_tools.runner import get_results

            _, fails = get_results(results)
            failed += fails
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
