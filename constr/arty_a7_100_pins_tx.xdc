# Arty A7-100T pins used only by examples that transmit (examples/udp_echo); read after
# arty_a7_100_pins.xdc. Line copied verbatim (uncommented) from Digilent's
# Arty-A7-100-Master.xdc, github.com/Digilent/digilent-xdc commit
# bb01f62e09a8d8d5e85971aa12cf1d15e0f48207 (2022-06-01), MIT licence, by script
# (sed on the fetched file), not typed: do not edit pins by hand.
set_property -dict { PACKAGE_PIN H16   IOSTANDARD LVCMOS33 } [get_ports { eth_tx_clk }]; #IO_L13P_T2_MRCC_15 Sch=eth_tx_clk
