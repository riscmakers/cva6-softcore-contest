
// *****************************************************************
// Data cache data store (SRAM)
// Inferring Xilinx block ram IP
// Currently a simple implementation, with separate write/read ports
// 
// Data store has a byte enable instead of bit enable, because
// we will only need to write/read at the byte boundary, whereas
// the tag store needs to set/clear at the bit boundary (valid/dirty)
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

// Data store cache that fits perfectly into Xilinx BRAM36K primitives
// With a total cache size of 32Kibytes, we need to create 8 Xilinx BRAM36K primitives
// In general, Cache_size (in multiples of 32Kibits if we're considering BRAM36K blocks
// or in multiples of 18Kibits) is divided by 32 or 18 to get the number of BRAM primitives
// (there are extra bits not used since the cache size is not a perfect multiple of 36K)
// Ahh but if we made it a perfect multiple that could be useful. But then its not a multiple of 2.
// Anyway, ignoring the extra bits, the block index is simply divided by the cache line width
// so if we want 128 bits cache line width, we will divide cache set by 128 => 2048 to get
// 32 Kibytes


import ariane_pkg::*; 
import wt_cache_pkg::*;
import dcache_pkg::*;

module dcache_data_store #(
    parameter int unsigned DATA_WIDTH = dcache_pkg::DCACHE_LINE_WIDTH,
    parameter int unsigned NUM_WORDS  = dcache_pkg::DCACHE_NUM_WORDS
)(
   input  logic                          clk_i,
   input  logic                          en_i,
   input  logic [DATA_WIDTH/8-1:0]       write_byte_i, // byte enable
   input  logic                          we_i,
   /* verilator lint_off UNUSED */
   input  logic                          rst_ni,
   /* verilator lint_on UNUSED */
   input  logic [$clog2(NUM_WORDS)-1:0]  addr_i,
   input  logic [DATA_WIDTH-1:0]         wdata_i,
   output logic [DATA_WIDTH-1:0]         rdata_o
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
                    if (write_byte_i[i]) begin
                        // pseudo-code that explains the following byte selection using 
                        // part-select addressing:
                        //
                        // (write_byte_i[0]) ? ram[addr_i][7:0] <= wdata_i[7:0];
                        // (write_byte_i[1]) ? ram[addr_i][15:8] <= wdata_i[15:8];
                        // etc...
                        ram[addr_i][i*BYTE_WIDTH +: BYTE_WIDTH] <= wdata_i[i*BYTE_WIDTH +: BYTE_WIDTH];
                    end
                end
            end
        end
    end


    assign rdata_o = ram[raddr_q];

endmodule