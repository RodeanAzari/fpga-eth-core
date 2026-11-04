// Lint/sim stand-in for the Xilinx BUFG primitive (never synthesized).
module BUFG (input wire I, output wire O);
    assign O = I;
endmodule
