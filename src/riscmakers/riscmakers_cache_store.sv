
//  Xilinx Single Port Byte-Write Write First RAM
//  This code implements a parameterizable single-port byte-write write-first memory where when data
//  is written to the memory, the output reflects the new memory contents.
//  If a reset or enable is not necessary, it may be tied off or removed from the code.
//  Modify the parameters for the desired RAM characteristics.

module riscmakers_cache_store #(
  parameter NB_COL = 4,                           // Specify number of columns (number of bytes)
  parameter COL_WIDTH = 9,                        // Specify column width (byte width, typically 8 or 9)
  parameter RAM_DEPTH = 1024,                     // Specify RAM depth (number of entries)
  parameter RAM_PERFORMANCE = "HIGH_PERFORMANCE", // Select "HIGH_PERFORMANCE" or "LOW_LATENCY" 
  parameter INIT_FILE = ""                        // Specify name/location of RAM initialization file if using one (leave blank if not)
) (
  input [clogb2(RAM_DEPTH-1)-1:0] addra,  // Address bus, width determined from RAM_DEPTH
  input [(NB_COL*COL_WIDTH)-1:0] dina,  // RAM input data
  input clka,                           // Clock
  input [NB_COL-1:0] wea,               // Byte-write enable
  input ena,                            // RAM Enable, for additional power savings, disable port when not in use
  input rsta,                           // Output reset (does not affect memory contents)
  input regcea,                         // Output register enable
  output [(NB_COL*COL_WIDTH)-1:0] douta          // RAM output data
);

  reg [(NB_COL*COL_WIDTH)-1:0] BRAM [RAM_DEPTH-1:0];
  reg [(NB_COL*COL_WIDTH)-1:0] ram_data = {(NB_COL*COL_WIDTH){1'b0}};

  // The following code either initializes the memory values to a specified file or to all zeros to match hardware
  generate
    if (INIT_FILE != "") begin: use_init_file
      initial
        $readmemh(INIT_FILE, BRAM, 0, RAM_DEPTH-1);
    end else begin: init_bram_to_zero
      integer ram_index;
      initial
        for (ram_index = 0; ram_index < RAM_DEPTH; ram_index = ram_index + 1)
          BRAM[ram_index] = {(NB_COL*COL_WIDTH){1'b0}};
    end
  endgenerate

  generate
  genvar i;
     for (i = 0; i < NB_COL; i = i+1) begin: byte_write
       always @(posedge clka)
         if (ena)
           if (wea[i]) begin
             BRAM[addra][(i+1)*COL_WIDTH-1:i*COL_WIDTH] <= dina[(i+1)*COL_WIDTH-1:i*COL_WIDTH];
             ram_data[(i+1)*COL_WIDTH-1:i*COL_WIDTH] <= dina[(i+1)*COL_WIDTH-1:i*COL_WIDTH];
           end else begin
             ram_data[(i+1)*COL_WIDTH-1:i*COL_WIDTH] <= BRAM[addra][(i+1)*COL_WIDTH-1:i*COL_WIDTH];
           end
      end
  endgenerate

  //  The following code generates HIGH_PERFORMANCE (use output register) or LOW_LATENCY (no output register)
  generate
    if (RAM_PERFORMANCE == "LOW_LATENCY") begin: no_output_register

      // The following is a 1 clock cycle read latency at the cost of a longer clock-to-out timing
       assign douta = ram_data;

    end else begin: output_register

      // The following is a 2 clock cycle read latency with improve clock-to-out timing

      reg [(NB_COL*COL_WIDTH)-1:0] douta_reg = {(NB_COL*COL_WIDTH){1'b0}};

      always @(posedge clka)
        if (rsta)
          douta_reg <= {(NB_COL*COL_WIDTH){1'b0}};
        else if (regcea)
          douta_reg <= ram_data;

      assign douta = douta_reg;

    end
  endgenerate

  //  The following function calculates the address width based on specified RAM depth
  function integer clogb2;
    input integer depth;
      for (clogb2=0; depth>0; clogb2=clogb2+1)
        depth = depth >> 1;
  endfunction

endmodule

// The following is an instantiation template for xilinx_single_port_byte_write_ram_write_first
/*
  //  Xilinx Single Port Byte-Write Write First RAM
  xilinx_single_port_byte_write_ram_write_first #(
    .NB_COL(4),                           // Specify number of columns (number of bytes)
    .COL_WIDTH(9),                        // Specify column width (byte width, typically 8 or 9)
    .RAM_DEPTH(1024),                     // Specify RAM depth (number of entries)
    .RAM_PERFORMANCE("HIGH_PERFORMANCE"), // Select "HIGH_PERFORMANCE" or "LOW_LATENCY" 
    .INIT_FILE("")                        // Specify name/location of RAM initialization file if using one (leave blank if not)
  ) your_instance_name (
    .addra(addra),     // Address bus, width determined from RAM_DEPTH
    .dina(dina),       // RAM input data, width determined from NB_COL*COL_WIDTH
    .clka(clka),       // Clock
    .wea(wea),         // Byte-write enable, width determined from NB_COL
    .ena(ena),         // RAM Enable, for additional power savings, disable port when not in use
    .rsta(rsta),       // Output reset (does not affect memory contents)
    .regcea(regcea),   // Output register enable
    .douta(douta)      // RAM output data, width determined from NB_COL*COL_WIDTH
  );
*/
							
						





// ======================================================================================================================================







// // Copyright 2014 ETH Zurich and University of Bologna.
// // Copyright and related rights are licensed under the Solderpad Hardware
// // License, Version 0.51 (the "License"); you may not use this file except in
// // compliance with the License.  You may obtain a copy of the License at
// // http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// // or agreed to in writing, software, hardware and materials distributed under
// // this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// // CONDITIONS OF ANY KIND, either express or implied. See the License for the
// // specific language governing permissions and limitations under the License.

// /**
//  * Inferable, Synchronous Single-Port N x 64bit RAM with Byte-Wise Enable
//  *
//  * This module contains an implementation for either Xilinx or Altera FPGAs.  To synthesize for
//  * Xilinx, define `FPGA_TARGET_XILINX`.  To synthesize for Altera, define `FPGA_TARGET_ALTERA`.  The
//  * implementations follow the respective guidelines:
//  * - Xilinx UG901 Vivado Design Suite User Guide: Synthesis (p. 106)
//  * - Altera Quartus II Handbook Volume 1: Design and Synthesis (p. 768)
//  *
//  * Current Maintainers:
//  * - Michael Schaffner  <schaffer@iis.ee.ethz.ch>
//  * 
//  * Modified by RISC Makers to be data width size configurable
//  */

// module riscmakers_cache_store
// #(
//   parameter DATA_WIDTH = 128,
//   parameter NUM_WORDS  = 2048,
//   parameter OUT_REGS   = 0,    // set to 1 to enable outregs
//   parameter SIM_INIT   = 0     // for simulation only, will not be synthesized
//                                // 0: no init, 1: zero init, 2: random init, 3: deadbeef init
//                                // note: on verilator, 2 is not supported. define the VERILATOR macro to work around.
// )(
//   input  logic                  Clk_CI,
//   input  logic                  Rst_RBI,
//   input  logic                  CSel_SI,
//   input  logic                  WrEn_SI,
//   input  logic [DATA_WIDTH/8-1:0] BEn_SI,
//   input  logic [DATA_WIDTH-1:0] WrData_DI,
//   input  logic [$clog2(NUM_WORDS)-1:0] Addr_DI,
//   output logic [DATA_WIDTH-1:0] RdData_DO
// );

//   ////////////////////////////
//   // signals, localparams
//   ////////////////////////////

//   localparam ADDR_WIDTH = $clog2(NUM_WORDS);
//   localparam DATA_BYTES = DATA_WIDTH/8;

//   logic [DATA_WIDTH-1:0] RdData_DN;
//   logic [DATA_WIDTH-1:0] RdData_DP;

//   ////////////////////////////
//   // XILINX implementation
//   ////////////////////////////

//     logic [DATA_WIDTH-1:0] Mem_DP[NUM_WORDS-1:0];

//     always_ff @(posedge Clk_CI) begin
//       //pragma translate_off
//       automatic logic [DATA_WIDTH-1:0] val;
//       if(Rst_RBI == 1'b0 && SIM_INIT>0) begin
//         for(int k=0; k<NUM_WORDS;k++) begin
//           if(SIM_INIT==1) val = '0;
//       `ifndef VERILATOR
//           else if(SIM_INIT==2) void'(randomize(val));
//       `endif
//           else val = 64'hdeadbeefdeadbeef;
//           Mem_DP[k] = val;
//         end
//       end else
//       //pragma translate_on
//       if(CSel_SI) begin
//         if(WrEn_SI) begin
//           for (int unsigned i = 0; i < DATA_BYTES; i++) begin
//               if (BEn_SI[i]) begin
//                   // pseudo-code that explains the following byte selection using 
//                   // part-select addressing:
//                   // if(BEn_SI[0]) Mem_DP[Addr_DI][7:0]   <= WrData_DI[7:0];
//                   // if(BEn_SI[1]) Mem_DP[Addr_DI][15:8]  <= WrData_DI[15:8];
//                   // if(BEn_SI[2]) Mem_DP[Addr_DI][23:16] <= WrData_DI[23:16];
//                   // etc...
//                   Mem_DP[Addr_DI][i*8 +: 8] <= WrData_DI[i*8 +: 8];
//               end
//           end
//         end
//         RdData_DN <= Mem_DP[Addr_DI];
//       end
//     end

//   ////////////////////////////
//   // optional output regs
//   ////////////////////////////

//   // output regs
//   generate
//     if (OUT_REGS>0) begin : g_outreg
//       always_ff @(posedge Clk_CI or negedge Rst_RBI) begin
//         if(Rst_RBI == 1'b0)
//         begin
//           RdData_DP  <= 0;
//         end
//         else
//         begin
//           RdData_DP  <= RdData_DN;
//         end
//       end
//     end
//   endgenerate // g_outreg

//   // output reg bypass
//   generate
//     if (OUT_REGS==0) begin : g_oureg_byp
//       assign RdData_DP  = RdData_DN;
//     end
//   endgenerate// g_oureg_byp

//   assign RdData_DO = RdData_DP;

//   ////////////////////////////
//   // assertions
//   ////////////////////////////

//   // pragma translate_off
//   assert property
//     (@(posedge Clk_CI) (longint'(2)**longint'(ADDR_WIDTH) >= longint'(NUM_WORDS)))
//     else $error("depth out of bounds");
//   // pragma translate_on

// endmodule // SyncSpRamBeNx64


// Check if the single port byte write read first consumes significantly less than write first. I dont think we need write first at all!

//  Xilinx Single Port Byte-Write Read First RAM
//  This code implements a parameterizable single-port byte-write read-first memory where when data
//  is written to the memory, the output reflects the prior contents of the memory location.
//  If a reset or enable is not necessary, it may be tied off or removed from the code.
//  Modify the parameters for the desired RAM characteristics.

// module xilinx_single_port_byte_write_ram_read_first #(
//   parameter NB_COL = 4,                           // Specify number of columns (number of bytes)
//   parameter COL_WIDTH = 9,                        // Specify column width (byte width, typically 8 or 9)
//   parameter RAM_DEPTH = 1024,                     // Specify RAM depth (number of entries)
//   parameter RAM_PERFORMANCE = "HIGH_PERFORMANCE", // Select "HIGH_PERFORMANCE" or "LOW_LATENCY" 
//   parameter INIT_FILE = ""                        // Specify name/location of RAM initialization file if using one (leave blank if not)
// ) (
//   input [clogb2(RAM_DEPTH-1)-1:0] addra,  // Address bus, width determined from RAM_DEPTH
//   input [(NB_COL*COL_WIDTH)-1:0] dina,  // RAM input data
//   input clka,                           // Clock
//   input [NB_COL-1:0] wea,               // Byte-write enable
//   input ena,                            // RAM Enable, for additional power savings, disable port when not in use
//   input rsta,                           // Output reset (does not affect memory contents)
//   input regcea,                         // Output register enable
//   output [(NB_COL*COL_WIDTH)-1:0] douta // RAM output data
// );

//   reg [(NB_COL*COL_WIDTH)-1:0] BRAM [RAM_DEPTH-1:0];
//   reg [(NB_COL*COL_WIDTH)-1:0] ram_data = {(NB_COL*COL_WIDTH){1'b0}};

//   // The following code either initializes the memory values to a specified file or to all zeros to match hardware
//   generate
//     if (INIT_FILE != "") begin: use_init_file
//       initial
//         $readmemh(INIT_FILE, BRAM, 0, RAM_DEPTH-1);
//     end else begin: init_bram_to_zero
//       integer ram_index;
//       initial
//         for (ram_index = 0; ram_index < RAM_DEPTH; ram_index = ram_index + 1)
//           BRAM[ram_index] = {(NB_COL*COL_WIDTH){1'b0}};
//     end
//   endgenerate

//   always @(posedge clka)
//     if (ena) begin
//       ram_data <= BRAM[addra];
//     end

//   generate
//   genvar i;
//      for (i = 0; i < NB_COL; i = i+1) begin: byte_write
//        always @(posedge clka)
//          if (ena)
//            if (wea[i])
//              BRAM[addra][(i+1)*COL_WIDTH-1:i*COL_WIDTH] <= dina[(i+1)*COL_WIDTH-1:i*COL_WIDTH];
//       end
//   endgenerate

//   //  The following code generates HIGH_PERFORMANCE (use output register) or LOW_LATENCY (no output register)
//   generate
//     if (RAM_PERFORMANCE == "LOW_LATENCY") begin: no_output_register

//       // The following is a 1 clock cycle read latency at the cost of a longer clock-to-out timing
//        assign douta = ram_data;

//     end else begin: output_register

//       // The following is a 2 clock cycle read latency with improve clock-to-out timing

//       reg [(NB_COL*COL_WIDTH)-1:0] douta_reg = {(NB_COL*COL_WIDTH){1'b0}};

//       always @(posedge clka)
//         if (rsta)
//           douta_reg <= {(NB_COL*COL_WIDTH){1'b0}};
//         else if (regcea)
//           douta_reg <= ram_data;

//       assign douta = douta_reg;

//     end
//   endgenerate

//   //  The following function calculates the address width based on specified RAM depth
//   function integer clogb2;
//     input integer depth;
//       for (clogb2=0; depth>0; clogb2=clogb2+1)
//         depth = depth >> 1;
//   endfunction

// endmodule

// // The following is an instantiation template for xilinx_single_port_byte_write_ram_read_first
// /*
//   //  Xilinx Single Port Byte-Write Read First RAM
//   xilinx_single_port_byte_write_ram_read_first #(
//     .NB_COL(4),                           // Specify number of columns (number of bytes)
//     .COL_WIDTH(9),                        // Specify column width (byte width, typically 8 or 9)
//     .RAM_DEPTH(1024),                     // Specify RAM depth (number of entries)
//     .RAM_PERFORMANCE("HIGH_PERFORMANCE"), // Select "HIGH_PERFORMANCE" or "LOW_LATENCY" 
//     .INIT_FILE("")                        // Specify name/location of RAM initialization file if using one (leave blank if not)
//   ) your_instance_name (
//     .addra(addra),     // Address bus, width determined from RAM_DEPTH
//     .dina(dina),       // RAM input data, width determined from NB_COL*COL_WIDTH
//     .clka(clka),       // Clock
//     .wea(wea),         // Byte-write enable, width determined from NB_COL
//     .ena(ena),         // RAM Enable, for additional power savings, disable port when not in use
//     .rsta(rsta),       // Output reset (does not affect memory contents)
//     .regcea(regcea),   // Output register enable
//     .douta(douta)      // RAM output data, width determined from NB_COL*COL_WIDTH
//   );
// */
			