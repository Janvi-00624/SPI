# =============================================================================
# SPI master/slave - build & test
#   make sim                       one simulation (MODE, CLK_DIV, DATA_WIDTH)
#   make sim MODE=3 CLK_DIV=8 DATA_WIDTH=16
#   make regress                   all modes x several widths x several dividers
#   make lint                      Verilator lint of the RTL
#   make wave                      open last waveform in GTKWave
#   make clean
# =============================================================================
IVERILOG   ?= iverilog
VVP        ?= vvp
VERILATOR  ?= verilator

SIM_DIR    := sim
RTL        := rtl/spi_master.v rtl/spi_slave.v
TB         := tb/tb_spi.v

MODE       ?= 0
CLK_DIV    ?= 4
DATA_WIDTH ?= 8

TAG        := m$(MODE)_d$(CLK_DIV)_w$(DATA_WIDTH)
VVP_FILE   := $(SIM_DIR)/spi_$(TAG).vvp
VCD_FILE   := $(SIM_DIR)/spi_$(TAG).vcd
LOG_FILE   := $(SIM_DIR)/spi_$(TAG).log

.PHONY: sim regress lint wave clean

sim:
	@mkdir -p $(SIM_DIR)
	@$(IVERILOG) -g2012 -Wall -P tb_spi.MODE=$(MODE) -P tb_spi.CLK_DIV=$(CLK_DIV) \
	    -P tb_spi.DATA_WIDTH=$(DATA_WIDTH) -o $(VVP_FILE) $(RTL) $(TB)
	@$(VVP) $(VVP_FILE) +VCD=$(VCD_FILE) > $(LOG_FILE)
	@grep -E "^(===|MODE=|RESULT)|ERROR" $(LOG_FILE) || true
	@grep -q "RESULT: PASS" $(LOG_FILE)

regress:
	@fail=0; n=0; \
	for w in 5 8 16; do for d in 3 4 8; do for m in 0 1 2 3; do \
	    n=$$((n+1)); \
	    $(MAKE) --no-print-directory sim MODE=$$m CLK_DIV=$$d DATA_WIDTH=$$w >/dev/null 2>&1 \
	        && echo "PASS  mode=$$m clk_div=$$d width=$$w" \
	        || { echo "FAIL  mode=$$m clk_div=$$d width=$$w  (see $(SIM_DIR)/spi_m$${m}_d$${d}_w$${w}.log)"; fail=$$((fail+1)); }; \
	done; done; done; \
	echo "----"; echo "$$n configurations, $$fail failed"; \
	[ $$fail -eq 0 ]

lint:
	$(VERILATOR) --lint-only -Wall rtl/spi_master.v --top-module spi_master
	$(VERILATOR) --lint-only -Wall rtl/spi_slave.v  --top-module spi_slave

wave:
	gtkwave $(VCD_FILE) &

clean:
	rm -f $(SIM_DIR)/*.vvp $(SIM_DIR)/*.vcd $(SIM_DIR)/*.log