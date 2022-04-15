
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

import ariane_pkg::*; 
import wt_cache_pkg::*;
import dcache_pkg::*;

module dcache_data_store #(
    parameter int unsigned DATA_WIDTH = dcache_pkg::DCACHE_DATA_WIDTH,
    parameter int unsigned NUM_WORDS  = wt_cache_pkg::DCACHE_NUM_WORDS
)(
   input  logic                          clk_i,
   input  logic                          en_i,
   input  logic [DATA_WIDTH/8-1:0]       write_byte_i, // byte enable
   input  logic                          we_i,
   input  logic [$clog2(NUM_WORDS)-1:0]  addr_i,
   input  logic [DATA_WIDTH-1:0]         wdata_i,
   output logic [DATA_WIDTH-1:0]         rdata_o
);
    localparam ADDR_WIDTH = $clog2(NUM_WORDS);
    localparam NUM_BYTES = DATA_WIDTH/8;
    localparam BYTE_WIDTH = 8;

    logic [DATA_WIDTH-1:0] ram [NUM_WORDS-1:0];
    logic [ADDR_WIDTH-1:0] raddr_q;

    // init reset values to 0
    initial begin
        for (int unsigned i = 0; i < NUM_WORDS; i++)
            ram[i] = 0;
    end

    always_ff @(posedge clk_i) begin
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








// //  Xilinx Simple Dual Port Single Clock RAM with Byte-write
//   //  This code implements a parameterizable SDP single clock memory.
//   //  If a reset or enable is not necessary, it may be tied off or removed from the code.

//   parameter NB_COL = <col>;                       // Specify number of columns (number of bytes)
//   parameter COL_WIDTH = <width>;                  // Specify column width (byte width, typically 8 or 9)
//   parameter RAM_DEPTH = <depth>;                  // Specify RAM depth (number of entries)
//   parameter RAM_PERFORMANCE = "HIGH_PERFORMANCE"; // Select "HIGH_PERFORMANCE" or "LOW_LATENCY" 
//   parameter INIT_FILE = "";                       // Specify name/location of RAM initialization file if using one (leave blank if not)

//   <wire_or_reg> [clogb2(RAM_DEPTH-1)-1:0] <addra>; // Write address bus, width determined from RAM_DEPTH
//   <wire_or_reg> [clogb2(RAM_DEPTH-1)-1:0] <addrb>; // Read address bus, width determined from RAM_DEPTH
//   <wire_or_reg> [(NB_COL*COL_WIDTH)-1:0] <dina>; // RAM input data
//   <wire_or_reg> <clka>;                          // Clock
//   <wire_or_reg> [NB_COL-1:0] <wea>;              // Byte-write enable
//   <wire_or_reg> <enb>;                           // Read Enable, for additional power savings, disable when not in use
//   <wire_or_reg> <rstb>;                          // Output reset (does not affect memory contents)
//   <wire_or_reg> <regceb>;                        // Output register enable
//   wire [(NB_COL*COL_WIDTH)-1:0] <doutb>;         // RAM output data

//   reg [(NB_COL*COL_WIDTH)-1:0] <ram_name> [RAM_DEPTH-1:0];
//   reg [(NB_COL*COL_WIDTH)-1:0] <ram_data> = {(NB_COL*COL_WIDTH){1'b0}};

//   // The following code either initializes the memory values to a specified file or to all zeros to match hardware
//   generate
//     if (INIT_FILE != "") begin: use_init_file
//       initial
//         $readmemh(INIT_FILE, <ram_name>, 0, RAM_DEPTH-1);
//     end else begin: init_bram_to_zero
//       integer ram_index;
//       initial
//         for (ram_index = 0; ram_index < RAM_DEPTH; ram_index = ram_index + 1)
//           <ram_name>[ram_index] = {(NB_COL*COL_WIDTH){1'b0}};
//     end
//   endgenerate

//   always @(posedge <clka>)
//     if (<enb>)
//       <ram_data> <= <ram_name>[<addrb>];

//   generate
//   genvar i;
//      for (i = 0; i < NB_COL; i = i+1) begin: byte_write
//        always @(posedge <clka>)
//          if (<wea>[i])
//            <ram_name>[<addra>][(i+1)*COL_WIDTH-1:i*COL_WIDTH] <= dina[(i+1)*COL_WIDTH-1:i*COL_WIDTH];
//       end
//   endgenerate

//   //  The following code generates HIGH_PERFORMANCE (use output register) or LOW_LATENCY (no output register)
//   generate
//     if (RAM_PERFORMANCE == "LOW_LATENCY") begin: no_output_register

//       // The following is a 1 clock cycle read latency at the cost of a longer clock-to-out timing
//        assign <doutb> = <ram_data>;

//     end else begin: output_register

//       // The following is a 2 clock cycle read latency with improve clock-to-out timing

//       reg [(NB_COL*COL_WIDTH)-1:0] doutb_reg = {(NB_COL*COL_WIDTH){1'b0}};

//       always @(posedge <clka>)
//         if (<rstb>)
//           doutb_reg <= {(NB_COL*COL_WIDTH){1'b0}};
//         else if (<regceb>)
//           doutb_reg <= <ram_data>;

//       assign <doutb> = doutb_reg;

//     end
//   endgenerate

//   //  The following function calculates the address width based on specified RAM depth
//   function integer clogb2;
//     input integer depth;
//       for (clogb2=0; depth>0; clogb2=clogb2+1)
//         depth = depth >> 1;
//   endfunction
						
						