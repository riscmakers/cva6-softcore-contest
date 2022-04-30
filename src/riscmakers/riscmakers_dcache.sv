// ===============================================================================
// Module: 
//  RISC Makers data cache
//  Bypassing cache
// ===============================================================================

// ******************
// Packages
// ******************

import ariane_pkg::*; 
import wt_cache_pkg::*;
import dcache_pkg::*;

// ************************
// Main module declaration
// ************************

module riscmakers_dcache 
#(
    parameter logic [wt_cache_pkg::CACHE_ID_WIDTH-1:0] RdAmoTxId = 1, // not used (AMOs are not enabled)
    parameter ariane_pkg::ariane_cfg_t ArianeCfg = ariane_pkg::ArianeDefaultConfig
) 
(
    input logic clk_i,   
    input logic rst_ni, 
    /* verilator lint_off UNUSED */
    input logic enable_i,  
    input logic flush_i,   
    output logic flush_ack_o, 
    input amo_req_t amo_req_i,
    output amo_resp_t amo_resp_o,
    output logic wbuffer_empty_o,   
    output logic wbuffer_not_ni_o,  
    input dcache_req_i_t [2:0] req_ports_i, // unused because we don't interface to PTW
    input dcache_rtrn_t mem_rtrn_i,         // unused because we don't use invalidation vector and some other fields
    /* verilator lint_on UNUSED */
    output logic miss_o, // only active for half a clock cycle; performance counters dont increment in debug mode
    output dcache_req_o_t [2:0] req_ports_o,
    input logic mem_rtrn_vld_i,
    output logic mem_data_req_o,
    input logic mem_data_ack_i,
    output dcache_req_t mem_data_o
);

    // *****************************
    // Internal signal declaration
    // *****************************

    // ----- miscellaneous ----
    dcache_state_t current_state_q, next_state_d;   // FSM state register
    writeback_t writeback_d, writeback_q;           // writeback buffer (register)
    logic [wt_cache_pkg::CACHE_ID_WIDTH-1:0] WrTxId; 

    // ----- flags ----
    logic pending_request;                      // do we have an active request from one of the request ports?
    request_port_select_t current_request_port; // from which port are we currently serving the request?
    logic is_cache_ready_for_request;           // can cache can service a new request? i.e. register the input request port data?
    logic tag_store_compare_done;               // active on the clock's falling edge, to indicate when we have compared and can determine hit/miss
    logic tag_compare_hit;                      // cache hit

    // ------ request ports ------
    dcache_req_i_t req_port_i_d, req_port_i_q; 

    // ----- cache stores -------
    tag_store_t tag_store;
    data_store_t data_store;

    // ------ address -------
    logic [riscv::PLEN-1:0] req_port_address; // the complete physical address used by the output memory request port during load
    logic [dcache_pkg::DCACHE_CL_IDX_WIDTH-1:0] store_index; // the cache block index bits (indexes into the stores)
    logic [riscv::PLEN-1:0] memory_address; // memory address aligned to the corresponding size request 
    logic [dcache_pkg::DCACHE_OFFSET_WIDTH-riscv::XLEN_ALIGN_BYTES-1:0] cache_block_offset; // to know where to place the CPU provided word in the data store

    // ******************************
    // Continuous assignment signals
    // ******************************

    assign WrTxId = 2;
    assign current_request_port = (req_port_i_d.data_we) ? STORE_UNIT_PORT : LOAD_UNIT_PORT;
    assign pending_request = req_ports_i[LOAD_UNIT_PORT].data_req | req_ports_i[STORE_UNIT_PORT].data_req;
    assign req_port_address = {req_port_i_d.address_tag, req_port_i_d.address_index};
    assign mem_data_o.nc = (~enable_i) | (~ariane_pkg::is_inside_cacheable_regions(ArianeCfg, {{{64-ariane_pkg::DCACHE_TAG_WIDTH-ariane_pkg::DCACHE_INDEX_WIDTH}{1'b0}}, req_port_i_d.address_tag, {ariane_pkg::DCACHE_INDEX_WIDTH{1'b0}}})); 
    assign store_index = req_port_i_d.address_index[dcache_pkg::DCACHE_INDEX_WIDTH-1:dcache_pkg::DCACHE_OFFSET_WIDTH]; // currently, we only read/write the cache set the CPU requests
    assign tag_store_compare_done = ~clk_i; // a bit cheeky, but avoids having to register anything. on rising clock edge state can change, on falling clock edge we will always compare
    assign tag_compare_hit = ((tag_store.data_i.tag == req_port_i_d.address_tag) && (tag_store.data_i.valid));
    assign memory_address = cpu_to_memory_address(req_port_address, {1'b0, req_port_i_d.data_size});
    assign cache_block_offset = memory_address[dcache_pkg::DCACHE_OFFSET_WIDTH-1:riscv::XLEN_ALIGN_BYTES];

    // ****************************
    // Instantiated modules
    // ****************************

    dcache_data_store #(
        .DATA_WIDTH(dcache_pkg::DCACHE_LINE_WIDTH),
        .NUM_WORDS(dcache_pkg::DCACHE_NUM_WORDS)
    ) i_dcache_data_store (
        .clk_i(clk_i),
        .en_i(data_store.enable),
        .we_i(data_store.write_enable),
        .rst_ni(rst_ni),
        .write_byte_i(data_store.byte_enable),
        .addr_i(store_index),
        .wdata_i(data_store.data_o),
        .rdata_o(data_store.data_i)  
    );
    
    dcache_tag_store #(
        .DATA_WIDTH(dcache_pkg::DCACHE_TAG_STORE_DATA_WIDTH), 
        .NUM_WORDS(dcache_pkg::DCACHE_NUM_WORDS)
    ) i_dcache_tag_store (
        .clk_i(clk_i),
        .en_i(tag_store.enable),
        .we_i(tag_store.write_enable),
        .rst_ni(rst_ni),
        .addr_i(store_index),
        .wdata_i(tag_store.data_o),
        .bit_en_i(tag_store.bit_enable),      
        .rdata_o(tag_store.data_i)
    );

    // *******************************
    // Requests
    // *******************************

    // -------- mux selected request port data ---------
    always_comb begin: register_request_port_input
        if (is_cache_ready_for_request & pending_request) begin
            if (req_ports_i[LOAD_UNIT_PORT].data_req) begin
                req_port_i_d = req_ports_i[LOAD_UNIT_PORT]; // load priority
            end 
            else begin 
                req_port_i_d = req_ports_i[STORE_UNIT_PORT]; 
            end 
        end 
        else begin
            req_port_i_d = req_port_i_q;
        end 
    end 

    always_comb begin: is_cache_ready_for_request_flag
        if (current_state_q == IDLE) begin
            is_cache_ready_for_request = 1'b1;
        end 
        else begin 
            is_cache_ready_for_request = 1'b0;
        end
    end

    // *******************************
    // Cache finite state machine
    // *******************************

    always_comb begin: dcache_fsm
        
        // ----- miscellaneous ----
        next_state_d = current_state_q; 
        writeback_d = '0;
        miss_o = 1'b0;

        // ------ input/output request ports ------
        req_ports_o[STORE_UNIT_PORT].data_gnt = 1'b0;
        req_ports_o[STORE_UNIT_PORT].data_rdata = '0;
        req_ports_o[LOAD_UNIT_PORT].data_gnt = 1'b0;
        req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b0;
        req_ports_o[LOAD_UNIT_PORT].data_rdata = '0;

        // ------ main memory request port ------
        mem_data_req_o = 1'b0;
        mem_data_o.size = dcache_pkg::MEMORY_REQUEST_SIZE_CACHEBLOCK;
        mem_data_o.data = '0;  
        mem_data_o.paddr = '0;   
        mem_data_o.rtype = wt_cache_pkg::DCACHE_LOAD_REQ;
        mem_data_o.tid = RdAmoTxId;

        // ------ tag store ------
        tag_store.enable = 1'b0;           // disabled by default to help with energy consumption
        tag_store.write_enable = 1'b0;    
        tag_store.bit_enable = '0;    
        tag_store.data_o = '0;     

        // ------ data store -------
        data_store.enable = 1'b0;          // disabled by default to help with energy consumption
        data_store.write_enable = 1'b0;    // value is more likely because there are more loads than stores
        data_store.data_o = '0;            
        data_store.byte_enable = '0;  

        // ------- unused ---------
        req_ports_o[PTW_PORT] = '0;
        req_ports_o[STORE_UNIT_PORT].data_rvalid = 1'b0;

        // **********************
        // State logic
        // **********************
        case(current_state_q)

            IDLE : begin
                if (pending_request) begin
                    req_ports_o[current_request_port].data_gnt = 1'b1;  // grant the request

                    // are we requesting access to I/O space?
                    if (mem_data_o.nc) begin // yes, so we don't need to compare tags since the cache will be bypassed
                        mem_data_o.rtype    = (current_request_port == LOAD_UNIT_PORT) ? DCACHE_LOAD_REQ : DCACHE_STORE_REQ;
                        mem_data_o.tid      = (current_request_port == LOAD_UNIT_PORT) ? RdAmoTxId : WrTxId;
                        mem_data_o.size     = {1'b0, req_port_i_d.data_size};
                        mem_data_o.paddr    = cpu_to_memory_address(req_port_address, mem_data_o.size);
                        mem_data_o.data     = req_port_i_d.data_wdata;
                        mem_data_req_o      = 1'b1;

                        next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_BYPASS_DONE : WAIT_MEMORY_BYPASS_ACK;
                    end 
                    else begin // no, it's a cacheable request so we will compare tags and check for a cache hit                        
                        tag_store.enable = 1'b1;

                        if (tag_store_compare_done) begin // this will go high at the falling edge of this clock cycle, so wait until then
                            if (tag_compare_hit) begin // cache hit
                                if (current_request_port == LOAD_UNIT_PORT) begin // cache hit on a load
                                    tag_store.enable = 1'b0;   // tags, valid and dirty bits don't need to change
                                    data_store.enable = 1'b1;  // data will be available on the next rising clock edge
                                    next_state_d = LOAD_CACHE_HIT;      
                                end
                                else begin // cache hit on a store 
                                    tag_store.write_enable = 1'b1; // for updating the dirty bit (valid bit should already be valid becasue of tag_compare_hit)
                                    tag_store.data_o.dirty = 1'b1;
                                    tag_store.bit_enable.dirty = 1'b1; 

                                    data_store.write_enable = 1'b1; // write will occur on following rising clock edge
                                    data_store.enable = 1'b1;
                                    
                                    // figure out where to place the word from the CPU in the data store (not sure if address alignment is necessary)
                                    data_store.data_o[cache_block_offset*riscv::XLEN +: riscv::XLEN] = req_port_i_d.data_wdata;
                                    data_store.byte_enable = to_byte_enable16(memory_address[dcache_pkg::DCACHE_OFFSET_WIDTH-1:0], {1'b0, req_port_i_d.data_size});

                                    next_state_d = IDLE;  
                                end 
                            end 
                            else begin // cache miss 
                                miss_o = 1'b1;

                                if (tag_store.data_i.valid & tag_store.data_i.dirty) begin // need to writeback dirty data in cache, so update buffer
                                    writeback_d.flag = 1'b1;
                                    writeback_d.address = {tag_store.data_i.tag, req_port_i_d.address_index};
                                    writeback_d.data = cache_block_to_cpu_word(
                                                            data_store.data_i,
                                                            writeback_d.address,
                                                            1'b0 // being explicit here... we shouldn't have performed a tag comparision if this was == 1'b1
                                                       );
                                end 

                                if (current_request_port == STORE_UNIT_PORT) begin // store cache miss - write allocate data immediately
                                    tag_store.write_enable = 1'b1; // for updating dirty, valid, and new tags 
                                    tag_store.data_o.tag = req_port_i_d.address_tag;
                                    tag_store.data_o.dirty = 1'b1;
                                    tag_store.data_o.valid = 1'b1;
                                    tag_store.bit_enable = '1; 

                                    data_store.write_enable = 1'b1; // write will occur on following rising clock edge
                                    data_store.enable = 1'b1;
                                    
                                    // figure out where to place the word from the CPU in the data store (not sure if address alignment is necessary)
                                    data_store.data_o[cache_block_offset*riscv::XLEN +: riscv::XLEN] = req_port_i_d.data_wdata;
                                    data_store.byte_enable = to_byte_enable16(memory_address[dcache_pkg::DCACHE_OFFSET_WIDTH-1:0], {1'b0, req_port_i_d.data_size});   

                                    if (writeback_d.flag) begin // request writeback transaction immediately
                                        mem_data_o.rtype    = DCACHE_STORE_REQ;
                                        mem_data_o.tid      = WrTxId;
                                        mem_data_o.size     = {1'b0, req_port_i_d.data_size};
                                        mem_data_o.paddr    = cpu_to_memory_address(writeback_d.address, mem_data_o.size);
                                        mem_data_o.data     = writeback_d.data;
                                        mem_data_req_o      = 1'b1;   

                                        next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_WRITEBACK_DONE : WAIT_MEMORY_WRITEBACK_ACK;                                  
                                    end 
                                    else begin // no need to writeback, so we will simply write allocate CPU word and go back to IDLE
                                        next_state_d = IDLE;
                                    end 
                                                                     
                                end 

                                else begin // load cache miss - start main memory transaction request for a load
                                // Note: we might have to bail a load request, but because we're not going to write to the data or tag store
                                //       unless the request is completed, we don't have to do any special cleanup. we just ignore the writeback flag.
                                    tag_store.enable = 1'b0;   // tags, valid and dirty bits don't need to change until after the transaction is complete

                                    mem_data_o.rtype    = DCACHE_LOAD_REQ;
                                    mem_data_o.tid      = RdAmoTxId;                
                                    mem_data_o.size     = dcache_pkg::MEMORY_REQUEST_SIZE_CACHEBLOCK;
                                    mem_data_o.paddr    = cpu_to_memory_address(req_port_address, mem_data_o.size);
                                    mem_data_req_o      = 1'b1;

                                    next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_READ_DONE : WAIT_MEMORY_READ_ACK; 

                                end 


                            end 
                        end 
                    end 
                end
            end

            LOAD_CACHE_HIT : begin
                // don't need to pay attention to kill request, data_rvalid flag will go high regardless
                req_ports_o[LOAD_UNIT_PORT].data_rdata = cache_block_to_cpu_word(
                                                            data_store.data_i,
                                                            req_port_address,
                                                            1'b0 // being explicit here... we shouldn't be in this state if we had a non-cacheable request address
                                                        );
                req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1; // let the load unit know the data is available
                next_state_d = IDLE;
            end

            WAIT_MEMORY_WRITEBACK_ACK : begin
                // don't need to pay attention to kill request, because we only writeback if there was a CPU store or if we already served a load miss
                // keep the request active until it is acknowledged by main memory
                mem_data_o.rtype    = DCACHE_STORE_REQ;
                mem_data_o.tid      = WrTxId;
                mem_data_o.size     = {1'b0, req_port_i_d.data_size};
                mem_data_o.paddr    = cpu_to_memory_address(writeback_q.address, mem_data_o.size); // use flip-flop output because we latched in IDLE
                mem_data_o.data     = writeback_q.data;                                            // use flip-flop output because we latched in IDLE
                mem_data_req_o      = 1'b1;   

                next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_WRITEBACK_DONE : WAIT_MEMORY_WRITEBACK_ACK;     
            end 

            WAIT_MEMORY_WRITEBACK_DONE : begin
                // is the main memory transaction finished and was it the transaction type we were expecting?
                if ( mem_rtrn_vld_i && (mem_rtrn_i.rtype == DCACHE_STORE_ACK) ) begin
                    next_state_d = IDLE;
                end 
            end 

            WAIT_MEMORY_READ_ACK: begin
                if (req_ports_i[LOAD_UNIT_PORT].kill_req) begin // prematurely bail the load request 
                    next_state_d = IDLE;
                    req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1;
                end 
                else begin // keep the request active until it is acknowledged by main memory
                    mem_data_o.rtype    = DCACHE_LOAD_REQ;
                    mem_data_o.tid      = RdAmoTxId;                
                    mem_data_o.size     = dcache_pkg::MEMORY_REQUEST_SIZE_CACHEBLOCK;
                    mem_data_o.paddr    = cpu_to_memory_address(req_port_address, mem_data_o.size);
                    mem_data_req_o      = 1'b1;

                    next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_READ_DONE : WAIT_MEMORY_READ_ACK; 
                end          
            end 


            WAIT_MEMORY_READ_DONE : begin
                if (req_ports_i[LOAD_UNIT_PORT].kill_req) begin // prematurely bail the load request 
                    next_state_d = IDLE;
                    req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1; 
                end 
                // is the main memory transaction finished and was it the transaction type we were expecting?
                else if ( mem_rtrn_vld_i && (mem_rtrn_i.rtype == DCACHE_LOAD_ACK) ) begin
                    req_ports_o[LOAD_UNIT_PORT].data_rdata = cache_block_to_cpu_word(
                                                                mem_rtrn_i.data,
                                                                req_port_address,
                                                                mem_data_o.nc
                                                             );

                    req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1;

                    // now we need to write the cache block we just got from main memory into our data store, and update tags
                    tag_store.enable = 1'b1;
                    tag_store.write_enable = 1'b1; // for updating dirty, valid, and new tags 
                    tag_store.data_o.tag = req_port_i_d.address_tag;
                    tag_store.data_o.dirty = 1'b0; // we're clean! we just got this cache block from main memory
                    tag_store.data_o.valid = 1'b1;
                    tag_store.bit_enable = '1; 

                    data_store.write_enable = 1'b1; // write will occur on following rising clock edge
                    data_store.enable = 1'b1;
                    
                    data_store.data_o = mem_rtrn_i.data;
                    data_store.byte_enable = '1;                    

                    // do we still have to writeback data? this was determined earlier when we served the cache load miss in IDLE 
                    if (writeback_q.flag) begin // yes, so lets start a writeback request
                        mem_data_o.rtype    = DCACHE_STORE_REQ;
                        mem_data_o.tid      = WrTxId;
                        mem_data_o.size     = {1'b0, req_port_i_d.data_size};
                        mem_data_o.paddr    = cpu_to_memory_address(writeback_q.address, mem_data_o.size); // use flip-flop output because we latched in IDLE
                        mem_data_o.data     = writeback_q.data;                                            // use flip-flop output because we latched in IDLE
                        mem_data_req_o      = 1'b1;   

                        next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_WRITEBACK_DONE : WAIT_MEMORY_WRITEBACK_ACK;                         
                    end 
                    else begin // nope, so we can serve a new CPU request 
                        next_state_d = IDLE;
                    end                         
                end 
            end 


            WAIT_MEMORY_BYPASS_ACK : begin
                if (req_ports_i[LOAD_UNIT_PORT].kill_req) begin // prematurely bail the load request 
                    next_state_d = IDLE;
                    req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1;
                end 
                else begin // keep the request active until it is acknowledged by main memory
                    mem_data_o.rtype    = (current_request_port == LOAD_UNIT_PORT) ? DCACHE_LOAD_REQ : DCACHE_STORE_REQ;
                    mem_data_o.tid      = (current_request_port == LOAD_UNIT_PORT) ? RdAmoTxId : WrTxId;                
                    mem_data_o.size     = {1'b0, req_port_i_d.data_size};
                    mem_data_o.paddr    = cpu_to_memory_address(req_port_address, mem_data_o.size);
                    mem_data_o.data     = req_port_i_d.data_wdata;
                    mem_data_req_o      = 1'b1;

                    next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_BYPASS_DONE : WAIT_MEMORY_BYPASS_ACK;
                end 
            end 

            WAIT_MEMORY_BYPASS_DONE : begin
                if (req_ports_i[LOAD_UNIT_PORT].kill_req) begin // prematurely bail the load request 
                    next_state_d = IDLE;
                    req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1; 
                end 
                // is the main memory transaction finished and was it the transaction type we were expecting?
                else if ( mem_rtrn_vld_i && ( mem_rtrn_i.rtype == ( (current_request_port == STORE_UNIT_PORT) ? DCACHE_STORE_ACK : DCACHE_LOAD_ACK ) ) ) begin
                    if (current_request_port == LOAD_UNIT_PORT) begin // only the load unit expects return data
                        req_ports_o[LOAD_UNIT_PORT].data_rdata = cache_block_to_cpu_word(
                                                                    mem_rtrn_i.data,
                                                                    req_port_address,
                                                                    mem_data_o.nc
                                                                );

                        req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1;
                    end

                    next_state_d = IDLE;
                end 
            end 
        endcase
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

   always_ff @(posedge(clk_i)) begin: update_port_output_register
        if (!rst_ni) begin
            req_port_i_q <= '0;
        end 
        else begin
            req_port_i_q <= req_port_i_d;
        end
    end

   always_ff @(posedge(clk_i)) begin: update_writeback_register
        if (!rst_ni) begin
            writeback_q <= '0;
        end 
        // if we missed and the cache block we're replacing is dirty, save writeback data before it is overwritten by CPU data
        else if ( (miss_o == 1'b1) && (tag_store.data_i.valid & tag_store.data_i.dirty) ) begin
            writeback_q <= writeback_d;
        end
    end

    // *************************************
    // Unused module ports (not implemented)
    // *************************************
    assign flush_ack_o = 1'b1;              // flush is not implemented, but let CPU know it is always performed
    assign wbuffer_empty_o = 1'b1;          // write buffer is not implemented, so its always "empty"
    assign wbuffer_not_ni_o = 1'b1;         // not sure about what I should set this to, 
                                            // but in 'ariane.sv' there is this: 'assign dcache_commit_wbuffer_not_ni = 1'b1;' for the std_dcache 
                                            // and in load_unit.sv this needs to == 1 in WAIT_WB_EMPTY state
    assign amo_resp_o = '0;                 // might need to set this to always acknowledged?
    assign mem_data_o.amo_op = AMO_NONE;    // AMOs are not implemented
    assign mem_data_o.way = '0;             // I think this field is only for OpenPiton

// ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑  SYNTHESIZEABLE CODE   ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑
//
//
// ↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓ NON-SYNTHESIZABLE CODE ↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓


    // ****************************
    // Assertions
    // ****************************

    //pragma translate_off
    `ifndef VERILATOR

        initial begin
            assert (dcache_pkg::DCACHE_LINE_WIDTH >= riscv::XLEN)
            else begin $warning("Data cache line width is smaller than the processor word length"); end
        end
        assert property (@(posedge clk_i)(req_ports_i[LOAD_UNIT_PORT].data_we == 0))
            else begin $warning("Load unit port data_we is not always == 0"); end

        assert property (@(posedge clk_i)(req_ports_i[STORE_UNIT_PORT].data_we == 1))
            else begin $warning("Store unit port data_we is not always == 1"); end

        // TODO: check to see if unaligned load/store word requests arrive

    `endif
    //pragma translate_on

endmodule