# Scoped constraints for rx_reset_bridge (read with SCOPED_TO_REF rx_reset_bridge).
# Both crossings are levels into ASYNC_REG chains (a request held until acknowledged),
# so only the first flop of each chain is constrained: false path, as for reset_sync.
set_false_path -to [get_cells -hier -filter {NAME =~ *rx_sync_q_reg[0]*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *ack_sync_q_reg[0]*}]
