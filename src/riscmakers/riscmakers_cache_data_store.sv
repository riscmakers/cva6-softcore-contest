
// *****************************************************************
// Cache data store (SRAM)
// Inferring Xilinx block ram IP
// *****************************************************************
//
// Copyright 2017, 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Date: 13.10.2017
// Description: SRAM Behavioral Model
//
// Modified by RISC Makers

import ariane_pkg::*; 
import wt_cache_pkg::*;
import riscmakers_pkg::*;

module riscmakers_cache_data_store #(
    parameter int unsigned DATA_WIDTH = ariane_pkg::DCACHE_LINE_WIDTH, // these parameters (data cache configured) are overwritten in instantiation
    parameter int unsigned NUM_WORDS  = wt_cache_pkg::DCACHE_NUM_WORDS
)(
    input logic clk_i,
    /* verilator lint_off UNUSED */
    input logic rst_ni,
    /* verilator lint_on UNUSED */
    input logic en_i,
    input logic we_i, // write enable
    input logic [DATA_WIDTH/8-1:0] en_wr_byte_i, // byte enable
    input [$clog2(NUM_WORDS)-1:0] addr_i,
    input  logic [DATA_WIDTH-1:0] wdata_i,
    output logic [DATA_WIDTH-1:0] rdata_o

);

    localparam ADDR_WIDTH = $clog2(NUM_WORDS);
    localparam NUM_BYTES = DATA_WIDTH/8;
    localparam BYTE_WIDTH = 8;

    logic [DATA_WIDTH-1:0] ram [NUM_WORDS-1:0];
    logic [ADDR_WIDTH-1:0] raddr_q;

    always_ff @(posedge clk_i) begin

        // reset to 0 
        //pragma translate_off
        `ifndef VERILATOR
        if (!rst_ni) begin
            automatic logic [DATA_WIDTH-1:0] val;
            for (int unsigned k = 0; k < NUM_WORDS; k++) begin
                // for debugging purposes
                    void'(randomize(val));

                ram[k] = val;
            end
            raddr_q <= '0; 
        end 
        else
        `endif
        //pragma translate_on

        if (en_i) begin
            if (!we_i) // if no write byte flag is set, this is a read request
                raddr_q <= addr_i;
            else begin
                for (int unsigned i = 0; i < NUM_BYTES; i++) begin
                    if (en_wr_byte_i[i]) begin
                        // pseudo-code that explains the following byte selection using 
                        // part-select addressing:
                        //
                        // (en_wr_byte_i[0]) ? ram[addr_i][7:0] <= wdata_i[7:0];
                        // (en_wr_byte_i[1]) ? ram[addr_i][15:8] <= wdata_i[15:8];
                        // etc...
                        ram[addr_i][i*BYTE_WIDTH +: BYTE_WIDTH] <= wdata_i[i*BYTE_WIDTH +: BYTE_WIDTH];
                    end
                end
            end
        end
    end 

    assign rdata_o = ram[raddr_q];

endmodule