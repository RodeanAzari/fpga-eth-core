# Scoped constraints for async_fifo (read with SCOPED_TO_REF async_fifo). Only the Gray
# pointers cross clock domains. Bound pointer-bit skew to one destination period so a
# synchronizer never samples a mix of two pointer values; -datapath_only drops clock skew.
set wr_clk [get_clocks -of_objects [get_ports wr_clk_i]]
set rd_clk [get_clocks -of_objects [get_ports rd_clk_i]]
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *wr_gray_q_reg* && IS_SEQUENTIAL}] \
    -to [get_cells -hier -filter {NAME =~ *wr_gray_sync_q_reg[0]*}] \
    [get_property PERIOD $rd_clk]
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *rd_gray_q_reg* && IS_SEQUENTIAL}] \
    -to [get_cells -hier -filter {NAME =~ *rd_gray_sync_q_reg[0]*}] \
    [get_property PERIOD $wr_clk]
