
// *****************************************************************
// Data cache tag store (SRAM)
// Inferring Xilinx block ram IP
// Sensitive to both clock edges:
//  - tag read occuring on falling edge of system clock
//  - tag write occuring on rising edge (if there is a cache hit)
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
import dcache_pkg::*;

module dcache_tag_store #(
    parameter int unsigned DATA_WIDTH = dcache_pkg::DCACHE_TAG_STORE_DATA_WIDTH, // tag width plus valid and dirty bit
    parameter int unsigned NUM_WORDS  = dcache_pkg::DCACHE_NUM_WORDS    // number of cache indexes
)(
   input  logic                          clk_i,
   input  logic                          en_i,
   input  logic                          we_i,
   input  logic                          rst_ni,
   input  logic [$clog2(NUM_WORDS)-1:0]  addr_i,
   input  tag_store_data_t               wdata_i,
   input  tag_store_bit_enable_t         bit_en_i,
   output tag_store_data_t               rdata_o
);
    localparam ADDR_WIDTH = $clog2(NUM_WORDS);

    logic [DATA_WIDTH-1:0] ram [NUM_WORDS-1:0];
    logic [ADDR_WIDTH-1:0] raddr_q;

    // read tag store on negative clock edge
    always_ff @(negedge clk_i) begin
        //pragma translate_off
        if (!rst_ni) begin
           raddr_q <= '0; 
        end
        else
        //pragma translate_on 
        if (en_i) begin
            raddr_q <= addr_i;
        end
    end

    // write tag store on positive clock edge
    always_ff @(posedge clk_i) begin

        // reset to 0 
        //pragma translate_off
        if (!rst_ni) begin
            automatic logic [DATA_WIDTH-1:0] val;
            for (int unsigned k = 0; k < NUM_WORDS; k++) begin
                // for debugging purposes, 
                `ifndef VERILATOR
                    void'(randomize(val));
                `endif
                
                ram[k] = val;
                // but the valid bit has to be cleared
                ram[k][TAG_STORE_VALID_BIT_POSITION] = 1'b0;

            end
        end 
        else
        //pragma translate_on

        if (en_i & we_i)
            for (int unsigned i = 0; i < DATA_WIDTH; i++)
                if (bit_en_i[i]) ram[addr_i][i] <= wdata_i[i]; // bit enable write
    end

    assign rdata_o = ram[raddr_q];

endmodule