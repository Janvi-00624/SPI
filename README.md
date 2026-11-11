# SPI Master / Slave (Verilog)

Parameterized, full-duplex SPI master and slave with a self-checking testbench
and a regression that sweeps all four SPI modes, several data widths and
several clock dividers.

* **All 4 modes** - `CPOL` / `CPHA` are parameters
* **Any word width** (>= 2) - `DATA_WIDTH` parameter, MSB first
* **Synthesizable slave** - single clock domain; `SCLK`, `CS_N`, `MOSI` are synchronized
  and edge-detected (no logic clocked by `SCLK`)
* **Multi-slave friendly** - slave tri-states `MISO` while `CS_N` is high
* **Verified** - 36 configurations, 66 transfers each, Verilator-lint clean

## Layout

```
SPI/
├── rtl/
│   ├── spi_master.v     # master
│   └── spi_slave.v      # slave
├── tb/
│   └── tb_spi.v         # self-checking testbench
├── sim/                 # build output (gitignored)
├── docs/                # notes / timing diagrams
├── .github/workflows/ci.yml
├── .vscode/
├── Makefile
├── .gitignore
└── README.md
```

## Quick start

Requires Icarus Verilog (>= 11) and `make`. Verilator (lint) and GTKWave (waves) are optional.

```
sudo apt install iverilog verilator gtkwave     # Debian/Ubuntu
brew install icarus-verilog verilator gtkwave   # macOS
```

```
make sim                                   # mode 0, 8-bit, CLK_DIV=4
make sim MODE=3 CLK_DIV=8 DATA_WIDTH=16    # any combination
make regress                               # full sweep (modes 0-3 x widths 5/8/16 x dividers 3/4/8)
make lint                                  # Verilator -Wall on the RTL
make wave MODE=3 CLK_DIV=8 DATA_WIDTH=16   # open that run's VCD in GTKWave
make clean
```

`make sim` exits non-zero on any failure, so it works in scripts and CI.
Expected output of a passing run:

```
=== tb_spi: MODE=0 (CPOL=0 CPHA=0)  DATA_WIDTH=8  CLK_DIV=4 ===
[920 ns] M->S 0x0  S->M 0xff  |  master_rx=0xff  slave_rx=0x0
...
MODE=0 DATA_WIDTH=8 CLK_DIV=4 : 66 transfers, 0 error(s)
RESULT: PASS
```

## Modes

| MODE | CPOL | CPHA | SCLK idle | Master/slave sample on | Shift on |
|------|------|------|-----------|------------------------|----------|
| 0    | 0    | 0    | low       | rising                 | falling  |
| 1    | 0    | 1    | low       | falling                | rising   |
| 2    | 1    | 0    | high      | falling                | rising   |
| 3    | 1    | 1    | high      | rising                 | falling  |

## `spi_master`

| Parameter    | Default | Meaning |
|--------------|---------|---------|
| `DATA_WIDTH` | 8       | Bits per word (>= 2) |
| `CLK_DIV`    | 4       | System-clock cycles per SCLK half period (>= 1). `f_sclk = f_clk / (2*CLK_DIV)` |
| `CPOL`,`CPHA`| 0, 0    | SPI mode |
| `CS_SETUP`   | 4       | Cycles between `CS_N` falling and the start of the first half period (>= 1) |
| `CS_GAP`     | 4       | Minimum cycles `CS_N` stays high between words (>= 1) |

| Port | Dir | Description |
|------|-----|-------------|
| `clk`, `rst_n` | in | System clock, active-low async reset |
| `start`   | in  | Pulse for 1 cycle to begin a transfer. Ignored while `busy` |
| `tx_data` | in  | Word to send, latched on `start` |
| `rx_data` | out | Word received, valid when `done` pulses |
| `busy`    | out | High from `start` until the transfer (including `CS_GAP`) is finished |
| `done`    | out | 1-cycle pulse when the transfer completes; `busy` falls on the same edge, so the next `start` may be issued in the very next cycle |
| `sclk`, `mosi`, `cs_n`, `miso` | - | SPI bus |

Example (100 MHz clock, `CLK_DIV=4`): SCLK = 12.5 MHz.

## `spi_slave`

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `DATA_WIDTH`, `CPOL`, `CPHA` | 8, 0, 0 | Must match the master |

| Port | Dir | Description |
|------|-----|-------------|
| `clk`, `rst_n` | in | Slave's own system clock (not SCLK) and async reset |
| `sclk`, `cs_n`, `mosi` | in | SPI bus (asynchronous inputs, synchronized internally) |
| `miso`    | out | Tri-stated while `cs_n` is high |
| `tx_data` | in  | Word to send; latched when `cs_n` falls, so keep it stable before selecting |
| `rx_data` | out | Last word received |
| `rx_valid`| out | 1-cycle pulse (in `clk` domain) when `rx_data` is fresh |

**Slave timing requirements**

* `f_clk(slave) >= ~8 x f_sclk` recommended (about 4x is the hard floor): the slave reacts to
  an SCLK edge about 3 of its own clock cycles later, and that must fit well inside half an SCLK period.
* `CS_N` must stay high for at least ~3 slave clock cycles between words (see master `CS_GAP`).
* One word per `CS_N` assertion; extra SCLK edges are ignored until `CS_N` is released.


## Synthesis

Synthesized with Yosys 0.66 (`synth_ice40`), default parameters
(8-bit, CLK_DIV=4, mode 0):

| Module     | LUT4 | FFs | Carry |
|------------|------|-----|-------|
| spi_master | 50   | 44  | 5     |
| spi_slave  | 22   | 36  | 2     |

The slave's MISO tri-state buffer is left as a generic cell (it would map to an SB_IO at the top level). No place-and-route or hardware testing
has been done yet.

## What the testbench checks

The slave runs on a **different clock (7 ns) than the master (10 ns)**, so the synchronizers are
exercised against an unrelated clock. For every transfer it checks master RX, slave RX, exactly
one slave `rx_valid` pulse, `CS_N` released, `busy` low and exactly `2*DATA_WIDTH` SCLK edges.
Globally it checks:

* directed patterns (all-0, all-1, alternating) and walking-one / walking-zero for every bit
* back-to-back transfers with zero idle cycles, plus 50 random transfers with random gaps
* `start` pulsed while busy is ignored (no extra transfer, no extra `done`)
* reset in the middle of a word, followed by a clean transfer
* SCLK sits at its idle level whenever `CS_N` is high
* `done` pulse count equals the number of transfers; watchdog prevents hangs

The checks were mutation-tested: deliberately breaking the slave's sample edge or the master's
edge count makes the testbench fail.

## Limitations / ideas

* One word per chip-select assertion (no multi-word bursts)
* MSB first only
* Single `cs_n` output; add a decoder or extra outputs for multiple slaves
* Master samples `MISO` directly; for long board traces or high `f_sclk`, add an input
  synchronizer/delay and increase `CLK_DIV`
* Possible additions: LSB-first option, `DATA_WIDTH` bursts, FIFO interface, formal properties
