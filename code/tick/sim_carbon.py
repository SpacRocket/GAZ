#!/usr/bin/env python3
"""Simulated EUA carbon feed.

Same access story as gas: no free real-time EUA source exists — ICE and EEX
both charge — so this is the source rather than a placeholder.

Carbon is the slowest-moving of the three legs and the one whose units differ:
EUR per tonne CO2, not per MWh. The spread calculation converts it using the
plant's carbon intensity, which is why the raw price is stored unconverted.
"""

import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gazfeed as gf  # noqa: E402 - path must be set first

NAME = "sim_carbon"
TABLE = "carbon"

INTERVAL = float(os.environ.get("GAZ_CARBON_INTERVAL", "9.1"))

# The liquid contract is the front December.
CONTRACT = "EUA_DEC26"

LEVEL = 71.0
price = LEVEL


def make_batch():
    global price
    price += 0.02 * (LEVEL - price) + random.gauss(0, 0.15)

    return (
        gf.SymbolVector([CONTRACT]),
        gf.FloatVector([round(price, 2)]),
        gf.SymbolVector(["SIM"]),
    )


if __name__ == "__main__":
    gf.run(NAME, TABLE, INTERVAL, make_batch)
