// ===============================================================================
//  RISC Makers data cache
// ===============================================================================

// ******************
// Packages
// ******************

import ariane_pkg::*; 
import wt_cache_pkg::*;
import riscmakers_pkg::*;

// ************************
// Main module declaration
// ************************

module riscmakers_icache 
#(
  parameter logic [CACHE_ID_WIDTH-1:0]  RdTxId             = 0,                                  // ID to be used for read transactions
  parameter ariane_pkg::ariane_cfg_t    ArianeCfg          = ariane_pkg::ArianeDefaultConfig     // contains cacheable regions
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,

  /* verilator lint_off UNUSED */
  input  logic                      flush_i,
  input  icache_areq_i_t            areq_i,
  /* verilator lint_on UNUSED */

  input  logic                      en_i,                 // enable icache
  output logic                      miss_o,               // to performance counter
  // address translation requests
  output icache_areq_o_t            areq_o,
  // data requests
  input  icache_dreq_i_t            dreq_i,
  output icache_dreq_o_t            dreq_o,
  // refill port
  input  logic                      mem_rtrn_vld_i,
  input  icache_rtrn_t              mem_rtrn_i,
  output logic                      mem_data_req_o,
  input  logic                      mem_data_ack_i,
  output icache_req_t               mem_data_o
);

    // *****************************
    // Internal types
    // *****************************

    typedef enum {
        IDLE,                       // wait for a CPU memory request
        WAIT_NON_SPECULATIVE_FLAG,  // wait for the CPU to indicate that the request is non-speculative
        TAG_COMPARE,
        WAIT_MEMORY_READ_ACK,       // wait for main memory to acknowledge read (load) request
        WAIT_MEMORY_READ_DONE,      // wait for main memory to return with read (load) data
        WAIT_KILL_REQUEST           // we got a kill request during main memory transaction: wait for memory to finish transfer before serving new requests
    } icache_state_t;

    // *****************************
    // Internal signal declaration
    // *****************************

    icache_state_t current_state_q, next_state_d;   // FSM state register
    logic bypass_cache_d, bypass_cache_q;           
    logic tag_compare_hit;                          // cache hit
    logic [riscv::PLEN-1:0] req_address_d, req_address_q; 
    icache_tag_store_t tag_store;
    icache_tag_store_byte_aligned_t tag_store_byte_aligned;
    icache_data_store_t data_store;
    logic addr_ni;

    // ******************************
    // Continuous assignment signals
    // ******************************

    assign mem_data_o.tid = RdTxId;
    assign data_store.address = req_address_d[ariane_pkg::ICACHE_INDEX_WIDTH-1:wt_cache_pkg::ICACHE_OFFSET_WIDTH]; // d output because we look at the incoming request
    assign tag_store.address = req_address_d[ariane_pkg::ICACHE_INDEX_WIDTH-1:wt_cache_pkg::ICACHE_OFFSET_WIDTH]; 
    assign tag_compare_hit = ( (tag_store.data_i.tag == req_address_q[riscv::PLEN-1:ICACHE_INDEX_WIDTH]) && (tag_store.data_i.valid) ); // q output because we latched in data from IDLE state
    assign req_address_d = (dreq_o.ready & dreq_i.req) ? dreq_i.vaddr : req_address_q; // virtual address == physical address when the MMU is not enabled
    assign dreq_o.vaddr = req_address_q;
    assign data_store.data_o = mem_rtrn_i.data;
    assign tag_store.data_o.tag = req_address_q[riscv::PLEN-1:ICACHE_INDEX_WIDTH];
    assign addr_ni = is_inside_nonidempotent_regions(ArianeCfg, req_address_q);
    // assign bypass_cache_d = 1'b1; // for debugging purposes, we can force bypass_cache_d to 1 so that the cache is always bypassed
    assign bypass_cache_d = (dreq_o.ready & dreq_i.req) ? mem_data_o.nc : bypass_cache_q;

    // we get a linter warning: Feedback to public clock or circular logic, but this seems to be due mem_data_o.paddr and mem_data_o.nc being in the same packed structure
    // when the (mem_data_o.nc) is set to 1'b1, the warning goes away, but stays even when we explictly set mem_data_o.nc to 1 (above)
    assign mem_data_o.nc = (~en_i) | (~ariane_pkg::is_inside_cacheable_regions(ArianeCfg, 
                                     {{{64-ariane_pkg::ICACHE_TAG_WIDTH-ariane_pkg::ICACHE_INDEX_WIDTH}{1'b0}}, 
                                     req_address_d[riscv::PLEN-1:ariane_pkg::ICACHE_INDEX_WIDTH], 
                                     {ICACHE_INDEX_WIDTH{1'b0}}}));

    assign mem_data_o.paddr = (mem_data_o.nc) ? {req_address_d[riscv::PLEN-1:ICACHE_INDEX_WIDTH], req_address_d[ICACHE_INDEX_WIDTH-1:3], 3'b0} :                                         // align to 64bit
                                                {req_address_d[riscv::PLEN-1:ICACHE_INDEX_WIDTH], req_address_d[ICACHE_INDEX_WIDTH-1:ICACHE_OFFSET_WIDTH], {ICACHE_OFFSET_WIDTH{1'b0}}}; // align to cl

    // ****************************
    // Instantiated modules
    // ****************************

    riscmakers_cache_store #(
        .NB_COL(ariane_pkg::ICACHE_LINE_WIDTH/8),                           // Specify number of columns (number of bytes)
        .COL_WIDTH(8),                        // Specify column width (byte width, typically 8 or 9)
        .RAM_DEPTH(wt_cache_pkg::ICACHE_NUM_WORDS),                     // Specify RAM depth (number of entries)
        .RAM_PERFORMANCE("LOW_LATENCY"), // Select "HIGH_PERFORMANCE" or "LOW_LATENCY" 
        .INIT_FILE("")                        // Specify name/location of RAM initialization file if using one (leave blank if not)
    ) i_riscmakers_icache_data_store (
        .addra(data_store.address),     // Address bus, width determined from RAM_DEPTH
        .dina(data_store.data_o ),       // RAM input data, width determined from NB_COL*COL_WIDTH
        .clka(clk_i),       // Clock
        .wea(data_store.byte_enable),         // Byte-write enable, width determined from NB_COL
        .ena(data_store.enable),         // RAM Enable, for additional power savings, disable port when not in use
        .rsta(rst_ni),       // Output reset (does not affect memory contents)
        .regcea(),   // Output register enable
        .douta(data_store.data_i)      // RAM output data, width determined from NB_COL*COL_WIDTH
    );

    riscmakers_cache_store #(
        .NB_COL(riscmakers_pkg::ICACHE_TAG_STORE_DATA_WIDTH/8),                           // Specify number of columns (number of bytes)
        .COL_WIDTH(8),                        // Specify column width (byte width, typically 8 or 9)
        .RAM_DEPTH(wt_cache_pkg::ICACHE_NUM_WORDS),                     // Specify RAM depth (number of entries)
        .RAM_PERFORMANCE("LOW_LATENCY"), // Select "HIGH_PERFORMANCE" or "LOW_LATENCY" 
        .INIT_FILE("")                        // Specify name/location of RAM initialization file if using one (leave blank if not)
    ) i_riscmakers_icache_tag_store (
        .addra(tag_store.address),     // Address bus, width determined from RAM_DEPTH
        .dina(tag_store_byte_aligned.data_o),       // RAM input data, width determined from NB_COL*COL_WIDTH
        .clka(clk_i),       // Clock
        .wea(tag_store_byte_aligned.byte_enable),         // Byte-write enable, width determined from NB_COL
        .ena(tag_store.enable),         // RAM Enable, for additional power savings, disable port when not in use
        .rsta(rst_ni),       // Output reset (does not affect memory contents)
        .regcea(),   // Output register enable
        .douta(tag_store_byte_aligned.data_i)      // RAM output data, width determined from NB_COL*COL_WIDTH
    );


    // riscmakers_cache_store #(
    //     .NUM_WORDS(wt_cache_pkg::ICACHE_NUM_WORDS),
    //     .DATA_WIDTH(ariane_pkg::ICACHE_LINE_WIDTH),
    //     .OUT_REGS(0),
    //     .SIM_INIT(1) // zeros
    // ) i_riscmakers_icache_data_store (
    //     .Clk_CI    ( clk_i   ),
    //     .Rst_RBI   ( rst_ni  ),
    //     .CSel_SI   ( data_store.enable  ),
    //     .WrEn_SI   ( data_store.write_enable    ),
    //     .BEn_SI    ( data_store.byte_enable   ),
    //     .WrData_DI ( data_store.data_o ),
    //     .Addr_DI   ( data_store.address  ),
    //     .RdData_DO ( data_store.data_i )
    // );

    // riscmakers_cache_store #(
    //     .NUM_WORDS(wt_cache_pkg::ICACHE_NUM_WORDS),
    //     .DATA_WIDTH(riscmakers_pkg::ICACHE_TAG_STORE_DATA_WIDTH),
    //     .OUT_REGS(0),
    //     .SIM_INIT(1) // zeros
    // ) i_riscmakers_icache_tag_store (
    //     .Clk_CI    ( clk_i   ),
    //     .Rst_RBI   ( rst_ni  ),
    //     .CSel_SI   ( tag_store.enable  ),
    //     .WrEn_SI   ( tag_store.write_enable    ),
    //     .BEn_SI    ( tag_store_byte_aligned.byte_enable   ),
    //     .WrData_DI ( tag_store_byte_aligned.data_o ),
    //     .Addr_DI   ( tag_store.address  ),
    //     .RdData_DO ( tag_store_byte_aligned.data_i )
    // );

    // *******************************
    // Byte alignment
    // *******************************

    always_comb begin: byte_align_tag_store
        tag_store_byte_aligned.data_o = '0; // for debugging purposes, otherwise unknown bits are present during simulation

        tag_store_byte_aligned.data_o.valid[0] = tag_store.data_o.valid; // LSB of the valid byte
        tag_store_byte_aligned.data_o.tag[ariane_pkg::ICACHE_TAG_WIDTH-1:0] = tag_store.data_o.tag; // only the tag bits that matter

        tag_store.data_i.valid = tag_store_byte_aligned.data_i.valid[0]; // LSB of the valid byte
        tag_store.data_i.tag = tag_store_byte_aligned.data_i.tag[ariane_pkg::ICACHE_TAG_WIDTH-1:0]; // only the tag bits that matter

        tag_store_byte_aligned.byte_enable.valid = tag_store.bit_enable.valid;
        tag_store_byte_aligned.byte_enable.tag = {$bits(tag_store_byte_aligned.byte_enable.tag){tag_store.bit_enable.tag}}; // tag bytes are either all enabled, or all disabled (no partial tag writes)
    end

    // *******************************
    // Cache finite state machine
    // *******************************

    always_comb begin: dcache_fsm
        
        // ----- miscellaneous ----
        next_state_d = current_state_q; 
        miss_o = 1'b0;

        // ------ request port ---------
        dreq_o.data = '0;
        dreq_o.ready = 1'b0;
        dreq_o.valid = 1'b0;
        mem_data_req_o = 1'b0;
        
        // ------ tag store ------
        tag_store.data_o.valid = 1'b0;
        tag_store.enable = 1'b0;  
        tag_store.write_enable = 1'b0;
        tag_store.bit_enable = '0;    

        // ------ data store -------
        data_store.enable = 1'b0; 
        data_store.write_enable = 1'b0; 
        data_store.byte_enable = '0;  

        // **********************
        // State logic
        // **********************
        case(current_state_q)

            IDLE : begin
                serve_new_request();
            end

            WAIT_NON_SPECULATIVE_FLAG: begin
                if (dreq_i.kill_s2) begin
                    serve_new_request();
                    //next_state_d = IDLE;
                end             
                else if (!dreq_i.spec || !addr_ni) begin
                    mem_data_req_o = 1'b1;
                    next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_READ_DONE : WAIT_MEMORY_READ_ACK;             
                end 
            end 

            TAG_COMPARE: begin
                if (dreq_i.kill_s2) begin
                    serve_new_request();
                    //next_state_d = IDLE;
                end 
                // (!dreq_i.spec || !addr_ni) I'm adding because its in cva6_icache.sv, not sure why we really need this
                // I think we need to wait for the request to no longer be speculative?
                // simulation seems to support this. Wait until the request is no longer speculative
                else if (!dreq_i.spec || !addr_ni) begin
                    // ========================
                    // Cache hit
                    // ========================
                    if (tag_compare_hit) begin 
                        dreq_o.data = icache_block_to_cpu_word(data_store.data_i, req_address_q, 1'b0);
                        dreq_o.valid = 1'b1; // let the load unit know the data is available

                        serve_new_request();
                        //next_state_d = IDLE;
                    end 
                    // ========================
                    // Cache miss
                    // ========================
                    else begin
                        miss_o = 1'b1;   
                        mem_data_req_o = 1'b1;
                        next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_READ_DONE : WAIT_MEMORY_READ_ACK; 
                    end 
                end 
            end 

            WAIT_MEMORY_READ_ACK: begin
                mem_data_req_o = 1'b1;
                next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_READ_DONE : WAIT_MEMORY_READ_ACK;         
            end 

             WAIT_MEMORY_READ_DONE : begin
                if (dreq_i.kill_s2) begin
                    // if there is a kill request at the exact moment the memory transfer completes,
                    // we need to return to IDLE (or serve a new request) otherwise we will be locked in the WAIT_KILL_REQUEST state
                    if ( mem_rtrn_vld_i && (mem_rtrn_i.rtype == ICACHE_IFILL_ACK) ) begin
                        serve_new_request();
                        //next_state_d = IDLE;
                    end 
                    // we need to go to KILL_REQUEST state, so that once the memory load finishes
                    // we don't use the output and instead we ignore it
                    else begin
                        next_state_d = WAIT_KILL_REQUEST;
                    end 
                end 
                // are we done fetching the cache block we missed on?
                else if ( mem_rtrn_vld_i && (mem_rtrn_i.rtype == ICACHE_IFILL_ACK) ) begin
                    // ==========================================
                    // Output word to CPU
                    // ==========================================
                    dreq_o.data = icache_block_to_cpu_word(mem_rtrn_i.data, req_address_q, mem_data_o.nc);
                    dreq_o.valid = 1'b1;     
                    // ======================================================================
                    // Allocate fetched cache block to store if cacheable
                    // ======================================================================
                    if (!bypass_cache_q) begin
                        data_store.enable = 1'b1;
                        data_store.write_enable = 1'b1;
                        data_store.byte_enable = '1;

                        tag_store.enable = 1'b1;
                        tag_store.write_enable = 1'b1;
                        tag_store.data_o.valid = 1'b1;
                        tag_store.bit_enable = '1;

                        next_state_d = IDLE;
                    end 
                    // we can serve a new request immediately because we won't be writing to the tag or data store if it was a non-cacheable request
                    else begin
                        serve_new_request();
                        //next_state_d = IDLE;
                    end 
                end 
            end 

            // TODO: optimization. If we have a kill request, we don't have to wait for the memory to return (and waste clock cycles doing nothing).
            //       we can just go to IDLE and serve a new request.
            //       To do this though, we need a way to uniquely identify each memory transaction. Otherwise, if we don't check, its
            //       possible that on the next cache miss, we will think that the correct data is returned, but its actually from the previous 
            //       request that was killed. We could keep track of this using the TID (cache ID transfers). When the TID is at its max, then
            //       we stall to wait for the last requests to clear before trying more
            WAIT_KILL_REQUEST : begin
                if (mem_rtrn_vld_i && mem_rtrn_i.rtype == ICACHE_IFILL_ACK) begin
                    serve_new_request();
                    //next_state_d = IDLE;
                end
            end 

        endcase // FSM state machine
    end

    // ***************************************
    // Sequential logic
    // ***************************************

    always_ff @(posedge(clk_i)) begin: update_state_register
        if (!rst_ni) begin
            current_state_q <= IDLE;
        end 
        else begin
            current_state_q <= next_state_d;
        end
    end

   always_ff @(posedge(clk_i)) begin: update_req_address_register
        if (!rst_ni) begin
            req_address_q <= '0;
        end 
        else begin
            req_address_q <= req_address_d;
        end
    end

   always_ff @(posedge(clk_i)) begin: update_bypass_flag
        if (!rst_ni) begin
            bypass_cache_q <= '0;
        end 
        else begin
            bypass_cache_q <= bypass_cache_d;
        end
    end

    // *************************************
    // Reused request code
    // *************************************

    function void serve_new_request();
        next_state_d = IDLE; // this gets overwritten below
        dreq_o.ready = 1'b1;
        if (dreq_i.req) begin
            // are we requesting access to I/O space or are we forcing the cache to be bypassed?
            if (bypass_cache_d) begin
                // yes, so we don't need to compare tags since the cache will be bypassed
                // is the request speculative? 
                if (dreq_i.spec) begin
                    next_state_d = WAIT_NON_SPECULATIVE_FLAG;
                end 
                // no, so we can immediately request memory transfer
                else begin
                    mem_data_req_o = 1'b1;
                    next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_READ_DONE : WAIT_MEMORY_READ_ACK;
                end 
            end 
            // no, it's a cacheable request so we will compare tags and check for a cache hit 
            else begin     
                // tag comparision result will be ready in next clock cycle
                // speculatively read from data store, assuming we will get a tag hit
                tag_store.enable = 1'b1;
                data_store.enable = 1'b1;
                next_state_d = TAG_COMPARE;                   
            end 
        end   
        // I think a kill signal can be issued at the same time as the request, so this will always 
        // be the final assignment to the next_state_d signal
        if (dreq_i.kill_s1) begin
            next_state_d = IDLE;
        end   
    endfunction

    // *****************************************
    // Unused module ports (not implemented)
    // *****************************************
    assign areq_o.fetch_req = 1'b0;
    assign areq_o.fetch_vaddr = '0;
    assign dreq_o.ex = '0;
    assign mem_data_o.way = '0;

endmodule