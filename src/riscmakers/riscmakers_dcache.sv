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
    parameter logic [wt_cache_pkg::CACHE_ID_WIDTH-1:0] RdAmoTxId = 1,
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
    input dcache_req_i_t [2:0] req_ports_i, // port[0] unused because we don't interface to PTW
    input dcache_rtrn_t mem_rtrn_i,         // we don't use invalidation vector and some other fields
    /* verilator lint_on UNUSED */
    output logic miss_o,                    // only active for half a clock cycle and performance counters don't increment in debug mode
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
    logic [$clog2(dcache_pkg::NUMBER_OF_WORDS_IN_CACHE_BLOCK):0] writeback_request_count_d, writeback_request_count_q; // how many requests have been ack'ed?
    logic [$clog2(dcache_pkg::NUMBER_OF_WORDS_IN_CACHE_BLOCK):0] writeback_finished_count_d, writeback_finished_count_q; // how many requests have been completed?
    logic [wt_cache_pkg::CACHE_ID_WIDTH-1:0] WrTxId; 
    logic bypass_cache;                             // force cache to be bypassed for debugging purposes
    logic load_cache_hit_flag;

    // ----- flags ----
    logic pending_request;                      // do we have an active request from one of the request ports?
    request_port_select_t current_request_port; // from which port are we currently serving the request?
    logic is_cache_ready_for_request;           // can cache can service a new request? i.e. register the input request port data?
    logic tag_compare_hit;                      // cache hit
    logic update_writeback_buffer;

    // ------ request ports ------
    dcache_req_i_t req_port_i_d, req_port_i_q; 

    // ----- cache stores -------
    tag_store_t tag_store;
    tag_store_byte_aligned_t tag_store_byte_aligned;
    data_store_t data_store;

    // ------ address -------
    logic [riscv::PLEN-1:0] req_port_address; // the complete physical address used by the output memory request port during load
    logic [wt_cache_pkg::DCACHE_CL_IDX_WIDTH-1:0] store_index; // the cache block index bits (indexes into the stores)
    logic [riscv::PLEN-1:0] memory_address; // memory address aligned to the corresponding size request 
    logic [wt_cache_pkg::DCACHE_OFFSET_WIDTH-riscv::XLEN_ALIGN_BYTES-1:0] cache_block_offset; // to know where to place the CPU provided word in the data store
    logic [riscv::XLEN_ALIGN_BYTES-1:0] cpu_offset; // to know where in the CPU word the data is located
    logic [wt_cache_pkg::DCACHE_OFFSET_WIDTH-1:0] store_offset; // to know where in the data store to store data (cache_block_offset only accounts for word offsets, this accounts for byte/half word)

    // ******************************
    // Continuous assignment signals
    // ******************************

    assign bypass_cache = 1'b0;
    assign WrTxId = 2;
    assign current_request_port = (req_port_i_d.data_we) ? STORE_UNIT_PORT : LOAD_UNIT_PORT;
    assign pending_request = req_ports_i[LOAD_UNIT_PORT].data_req | req_ports_i[STORE_UNIT_PORT].data_req;
    assign req_port_address = {req_port_i_d.address_tag, req_port_i_d.address_index};
    assign mem_data_o.nc = (~enable_i) | (~ariane_pkg::is_inside_cacheable_regions(ArianeCfg, {{{64-ariane_pkg::DCACHE_TAG_WIDTH-ariane_pkg::DCACHE_INDEX_WIDTH}{1'b0}}, req_port_i_d.address_tag, {ariane_pkg::DCACHE_INDEX_WIDTH{1'b0}}})); 
    assign store_index = req_port_i_d.address_index[ariane_pkg::DCACHE_INDEX_WIDTH-1:wt_cache_pkg::DCACHE_OFFSET_WIDTH]; // currently, we only read/write the cache set the CPU requests
    assign tag_compare_hit = ((tag_store.data_i.tag == req_port_i_q.address_tag) && (tag_store.data_i.valid));
    assign memory_address = cpu_to_memory_address(req_port_address, {1'b0, req_port_i_d.data_size});
    assign cache_block_offset = memory_address[wt_cache_pkg::DCACHE_OFFSET_WIDTH-1:riscv::XLEN_ALIGN_BYTES];

    // ****************************
    // Instantiated modules
    // ****************************

    dcache_data_store #(
        .DATA_WIDTH(ariane_pkg::DCACHE_LINE_WIDTH),
        .NUM_WORDS(wt_cache_pkg::DCACHE_NUM_WORDS)
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
        .NUM_WORDS(wt_cache_pkg::DCACHE_NUM_WORDS)
    ) i_dcache_tag_store (
        .clk_i(clk_i),
        .en_i(tag_store.enable),
        .we_i(tag_store.write_enable),
        .rst_ni(rst_ni),
        .write_byte_i(tag_store_byte_aligned.byte_enable),      
        .addr_i(store_index),
        .wdata_i(tag_store_byte_aligned.data_o),
        .rdata_o(tag_store_byte_aligned.data_i)
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
        if ( (current_state_q == IDLE) || (load_cache_hit_flag) ) begin
            is_cache_ready_for_request = 1'b1;
        end 
        else begin 
            is_cache_ready_for_request = 1'b0;
        end
    end

    always_comb begin: select_offset
        case (req_port_i_d.data_size)
            CPU_REQUEST_SIZE_FOUR_BYTES: begin          
                store_offset = { {riscv::XLEN_ALIGN_BYTES{1'b0}}, memory_address[wt_cache_pkg::DCACHE_OFFSET_WIDTH-1:riscv::XLEN_ALIGN_BYTES]};
                cpu_offset = '0;
            end 
            CPU_REQUEST_SIZE_TWO_BYTES: begin        
                store_offset = { {(riscv::XLEN_ALIGN_BYTES-1){1'b0}}, memory_address[wt_cache_pkg::DCACHE_OFFSET_WIDTH-1:riscv::XLEN_ALIGN_BYTES-1]};
                cpu_offset = {1'b0, memory_address[0]};
            end 
            CPU_REQUEST_SIZE_ONE_BYTE: begin          
                store_offset = memory_address[wt_cache_pkg::DCACHE_OFFSET_WIDTH-1:riscv::XLEN_ALIGN_BYTES-2];
                cpu_offset = memory_address[1:0];
            end 
            default: begin
                // if we get here, it's an error
                store_offset = '0;
                cpu_offset = '0;
            end 
        endcase 
    end 

    always_comb begin: byte_align_tag_store

        // for debugging purposes
        tag_store_byte_aligned.data_o = '0;

        tag_store_byte_aligned.data_o.valid[0] = tag_store.data_o.valid; // LSB of the valid byte
        tag_store_byte_aligned.data_o.dirty[0] = tag_store.data_o.dirty; // LSB of the dirty byte
        tag_store_byte_aligned.data_o.tag[ariane_pkg::DCACHE_TAG_WIDTH-1:0] = tag_store.data_o.tag; // only the tag bits that matter

        tag_store.data_i.valid = tag_store_byte_aligned.data_i.valid[0]; // LSB of the valid byte
        tag_store.data_i.dirty = tag_store_byte_aligned.data_i.dirty[0]; // LSB of the dirty byte
        tag_store.data_i.tag = tag_store_byte_aligned.data_i.tag[ariane_pkg::DCACHE_TAG_WIDTH-1:0]; // only the tag bits that matter

        tag_store_byte_aligned.byte_enable.valid = tag_store.bit_enable.valid;
        tag_store_byte_aligned.byte_enable.dirty = tag_store.bit_enable.dirty; 
        tag_store_byte_aligned.byte_enable.tag = {$bits(tag_store_byte_aligned.byte_enable.tag){tag_store.bit_enable.tag}}; // tag bytes are either all enabled, or all disabled


    end

    // *******************************
    // Cache finite state machine
    // *******************************

    always_comb begin: dcache_fsm
        
        // ----- miscellaneous ----
        next_state_d = current_state_q; 
        writeback_d = '0;
        miss_o = 1'b0;
        update_writeback_buffer = 1'b0;
        writeback_request_count_d = writeback_request_count_q;
        writeback_finished_count_d = writeback_finished_count_q;
        load_cache_hit_flag = 1'b0;

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
                    req_ports_o[current_request_port].data_gnt = 1'b1; // grant the request

                    // are we requesting access to I/O space or are we forcing the cache to be bypassed?
                    if (mem_data_o.nc | bypass_cache) begin
                        // yes, so we don't need to compare tags since the cache will be bypassed
                        mem_data_o.rtype    = (current_request_port == LOAD_UNIT_PORT) ? DCACHE_LOAD_REQ : DCACHE_STORE_REQ;
                        mem_data_o.tid      = (current_request_port == LOAD_UNIT_PORT) ? RdAmoTxId : WrTxId;
                        mem_data_o.size     = {1'b0, req_port_i_d.data_size};
                        mem_data_o.paddr    = cpu_to_memory_address(req_port_address, mem_data_o.size);
                        mem_data_o.data     = req_port_i_d.data_wdata;
                        mem_data_req_o      = 1'b1;

                        next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_BYPASS_DONE : WAIT_MEMORY_BYPASS_ACK;
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
            end

            TAG_COMPARE: begin
                // bail on the load request
                if (req_ports_i[LOAD_UNIT_PORT].kill_req) begin
                    next_state_d = IDLE;
                    req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1;
                end 
                // ========================
                // Cache hit
                // ========================
                else if (tag_compare_hit) begin 
                    // ========================
                    // Load cache hit
                    // ========================
                    // in this case, req_port_i_d is pointing to new request data, and req_port_i_q is from the previous clock cycle
                    if (!req_port_i_q.data_we) begin
                        load_cache_hit_flag = 1'b1;
                        req_ports_o[LOAD_UNIT_PORT].data_rdata = cache_block_to_cpu_word(data_store.data_i, {req_port_i_q.address_tag, req_port_i_q.address_index}, 1'b0);
                        req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1; // let the load unit know the data is available

                        // we can serve consecutive load->load, load->store, but not store->store or store->load
                        if (pending_request) begin
                            req_ports_o[current_request_port].data_gnt = 1'b1; // grant the request

                            // are we requesting access to I/O space or are we forcing the cache to be bypassed?
                            if (mem_data_o.nc | bypass_cache) begin
                                // yes, so we don't need to compare tags since the cache will be bypassed
                                mem_data_o.rtype    = (current_request_port == LOAD_UNIT_PORT) ? DCACHE_LOAD_REQ : DCACHE_STORE_REQ;
                                mem_data_o.tid      = (current_request_port == LOAD_UNIT_PORT) ? RdAmoTxId : WrTxId;
                                mem_data_o.size     = {1'b0, req_port_i_d.data_size};
                                mem_data_o.paddr    = cpu_to_memory_address(req_port_address, mem_data_o.size);
                                mem_data_o.data     = req_port_i_d.data_wdata;
                                mem_data_req_o      = 1'b1;

                                next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_BYPASS_DONE : WAIT_MEMORY_BYPASS_ACK;
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
                        // no consecutive request
                        else begin
                            next_state_d = IDLE; 
                        end 
                    end
                    // ========================
                    // Store cache hit
                    // ========================
                    else begin 
                        tag_store.write_enable = 1'b1; // for updating the dirty bit (valid bit should already be valid becasue of tag_compare_hit)
                        tag_store.data_o.dirty = 1'b1;
                        tag_store.bit_enable.dirty = 1'b1; 
                        tag_store.enable = 1'b1;

                        // figure out where to place the word from the CPU in the data store
                        data_store.data_o[cache_block_offset*riscv::XLEN +: riscv::XLEN] = req_port_i_d.data_wdata;
                        data_store.byte_enable = cache_block_byte_enable(memory_address[wt_cache_pkg::DCACHE_OFFSET_WIDTH-1:0], {1'b0, req_port_i_d.data_size});
                        data_store.write_enable = 1'b1; // write will occur on following rising clock edge
                        data_store.enable = 1'b1;

                        next_state_d = IDLE; 
                    end 
                     
                end 
                // ========================
                // Cache miss
                // ========================
                else begin
                    miss_o = 1'b1;

                    mem_data_o.rtype    = DCACHE_LOAD_REQ;
                    mem_data_o.tid      = RdAmoTxId;                
                    mem_data_o.size     = dcache_pkg::MEMORY_REQUEST_SIZE_CACHEBLOCK;
                    mem_data_o.paddr    = cpu_to_memory_address(req_port_address, mem_data_o.size);
                    mem_data_req_o      = 1'b1;

                    next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_READ_DONE : WAIT_MEMORY_READ_ACK; 
                end 
            end 



            WAIT_MEMORY_READ_ACK: begin
                // bail on the load request
                if (req_ports_i[LOAD_UNIT_PORT].kill_req) begin
                    next_state_d = IDLE;
                    req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1;
                end 
                // keep the request active until it is acknowledged by main memory
                else begin
                    mem_data_o.rtype    = DCACHE_LOAD_REQ;
                    mem_data_o.tid      = RdAmoTxId;                
                    mem_data_o.size     = dcache_pkg::MEMORY_REQUEST_SIZE_CACHEBLOCK;
                    mem_data_o.paddr    = cpu_to_memory_address(req_port_address, mem_data_o.size);
                    mem_data_req_o      = 1'b1;

                    next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_READ_DONE : WAIT_MEMORY_READ_ACK; 
                end          
            end 


             WAIT_MEMORY_READ_DONE : begin
                 // bail on the load request
                if (req_ports_i[LOAD_UNIT_PORT].kill_req) begin
                    next_state_d = IDLE;
                    req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1; 
                end 
                // are we done fetching the cache block we missed on?
                else if ( mem_rtrn_vld_i && (mem_rtrn_i.rtype == DCACHE_LOAD_ACK) ) begin
                    
                    // write it to the data store and update tag store
                    // fresh cache block from memory so tag entry should be clean (unless we have a store cache miss, see below)
                    data_store.data_o = mem_rtrn_i.data;                // (data) data
                    data_store.byte_enable = '1;                        // (data) data enable
                    data_store.write_enable = 1'b1;                     // (data) read/write
                    data_store.enable = 1'b1;                           // (data) store enable

                    tag_store.data_o.tag = req_port_i_d.address_tag;    // (tag) data
                    tag_store.data_o.dirty = 1'b0;                      // ""
                    tag_store.data_o.valid = 1'b1;                      // ""
                    tag_store.bit_enable = '1;                          // (tag) data enable
                    tag_store.write_enable = 1'b1;                      // (tag) read/write
                    tag_store.enable = 1'b1;                            // (tag) store enable

                    // ========================
                    // Load cache miss
                    // ========================
                    if (current_request_port == LOAD_UNIT_PORT) begin
                        req_ports_o[LOAD_UNIT_PORT].data_rdata = cache_block_to_cpu_word(mem_rtrn_i.data, req_port_address, 1'b0);
                        req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1;                       
                    end
                    // ========================
                    // Store cache miss
                    // ========================
                    else begin
                        // subsitute byte, half word, or word of the fetched cache block and mark it dirty
                        tag_store.data_o.dirty = 1'b1;

                        case (req_port_i_d.data_size)
                            CPU_REQUEST_SIZE_FOUR_BYTES: data_store.data_o[store_offset*riscv::XLEN +: riscv::XLEN] = req_port_i_d.data_wdata;
                            CPU_REQUEST_SIZE_TWO_BYTES:  data_store.data_o[store_offset*riscv::XLEN/2 +: riscv::XLEN/2] = req_port_i_d.data_wdata[cpu_offset*riscv::XLEN/2 +: riscv::XLEN/2];
                            CPU_REQUEST_SIZE_ONE_BYTE:   data_store.data_o[store_offset*riscv::XLEN/4 +: riscv::XLEN/4] = req_port_i_d.data_wdata[cpu_offset*riscv::XLEN/4 +: riscv::XLEN/4];
                            default: ;
                        endcase 
 
                    end 
                    // ==========================
                    // Cache miss with writeback
                    // ==========================
                    // do we still have to writeback data?
                    if (tag_store.data_i.valid & tag_store.data_i.dirty) begin
                        update_writeback_buffer = 1'b1;

                        writeback_d.flag = 1'b1; // not strictly necessary to buffer this, but for debugging it might be useful
                        writeback_d.address = cpu_to_memory_address({tag_store.data_i.tag, req_port_i_d.address_index}, dcache_pkg::MEMORY_REQUEST_SIZE_CACHEBLOCK);
                        writeback_d.data = data_store.data_i;

                        mem_data_o.rtype    = DCACHE_STORE_REQ;
                        mem_data_o.tid      = '0;                                // first word transfer, the count should be 0
                        mem_data_o.size     = dcache_pkg::MEMORY_REQUEST_SIZE_FOUR_BYTES;
                        mem_data_o.paddr    = writeback_d.address;               // first word transfer, so the base address is the cache block base address
                        mem_data_o.data     = writeback_d.data[riscv::XLEN-1:0]; // first word transfer, so we start with the first word in cache block
                        mem_data_req_o      = 1'b1;   

                        if (mem_data_ack_i) begin
                            writeback_request_count_d = writeback_request_count_q + 1;
                            next_state_d = WAIT_MEMORY_WRITEBACK_DONE;
                        end 
                        else begin
                            next_state_d = WAIT_MEMORY_WRITEBACK_ACK;
                        end 

                    end 
                    else begin
                        next_state_d = IDLE;
                    end         
                end 
            end 

            WAIT_MEMORY_WRITEBACK_ACK : begin
                // don't need to pay attention to kill request, because we only writeback if there was a CPU store or if we already served a load miss
                // keep the request active until it is acknowledged by main memory
                mem_data_o.rtype    = DCACHE_STORE_REQ;
                mem_data_o.tid      = '0;                                // first word transfer, the count should be 0
                mem_data_o.size     = dcache_pkg::MEMORY_REQUEST_SIZE_FOUR_BYTES;
                mem_data_o.paddr    = writeback_d.address;               // first word transfer, so the base address is the cache block base address
                mem_data_o.data     = writeback_d.data[riscv::XLEN-1:0]; // first word transfer, so we start with the first word in cache block
                mem_data_req_o      = 1'b1;   

                if (mem_data_ack_i) begin
                    writeback_request_count_d = writeback_request_count_q + 1;
                    next_state_d = WAIT_MEMORY_WRITEBACK_DONE;
                end 
                else begin
                    next_state_d = WAIT_MEMORY_WRITEBACK_ACK;
                end     

            end 

            WAIT_MEMORY_WRITEBACK_DONE : begin
                // one of the writeback word transfers is complete
                if ( mem_rtrn_vld_i && (mem_rtrn_i.rtype == DCACHE_STORE_ACK) ) begin
                    writeback_finished_count_d = writeback_finished_count_q + 1;
                end 

                // writeback complete: we requested all the words, and all the words were written back
                // *********** this state is reached but it shouldnt be. I think the RHS is wrong *********
                if (writeback_finished_count_d == dcache_pkg::NUMBER_OF_WORDS_IN_CACHE_BLOCK) begin
                    writeback_request_count_d = '0;
                    writeback_finished_count_d = '0;
                    next_state_d = IDLE;
                end 

                // we still haven't requested all the words
                // ******** i think the RHS is wrong ********
                else if (writeback_request_count_d != dcache_pkg::NUMBER_OF_WORDS_IN_CACHE_BLOCK) begin
                    mem_data_o.rtype    = DCACHE_STORE_REQ;
                    mem_data_o.tid      = writeback_request_count_d; // LHS expects 2 bits, RHS generates 3 bits
                    mem_data_o.size     = dcache_pkg::MEMORY_REQUEST_SIZE_FOUR_BYTES;
                    mem_data_o.paddr    = writeback_q.address + writeback_request_count_d*(riscv::XLEN/8);
                    mem_data_o.data     = writeback_q.data[writeback_request_count_d*riscv::XLEN +: riscv::XLEN];
                    mem_data_req_o      = 1'b1;   

                    if (mem_data_ack_i) begin
                        writeback_request_count_d = writeback_request_count_q + 1;
                    end 

                end 

            end


            WAIT_MEMORY_BYPASS_ACK : begin
                // bail the load request 
                if (req_ports_i[LOAD_UNIT_PORT].kill_req) begin
                    next_state_d = IDLE;
                    req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1;
                end 
                // keep the request active until it is acknowledged by main memory
                else begin
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
                // bail the load request 
                if (req_ports_i[LOAD_UNIT_PORT].kill_req) begin
                    next_state_d = IDLE;
                    req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1; 
                end 
                // is the main memory transaction finished and was it the transaction type we were expecting?
                else if ( mem_rtrn_vld_i && ( mem_rtrn_i.rtype == ( (current_request_port == STORE_UNIT_PORT) ? DCACHE_STORE_ACK : DCACHE_LOAD_ACK ) ) ) begin
                    // only the load unit expects return data
                    if (current_request_port == LOAD_UNIT_PORT) begin
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
        // if we missed and the cache block we're replacing is dirty, save writeback data before it is overwritten by CPU data.
        // the cache block is overwritten after we receive the missed cache block
        else if (update_writeback_buffer) begin
            writeback_q <= writeback_d;
        end
    end

   always_ff @(posedge(clk_i)) begin: update_writeback_count
        if (!rst_ni) begin
            writeback_request_count_q <= '0;
            writeback_finished_count_q <= '0;
        end 
        else begin
            writeback_request_count_q <= writeback_request_count_d;
            writeback_finished_count_q <= writeback_finished_count_d;
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
    assign amo_resp_o = '0;                 // AMOs are not implemented
    assign mem_data_o.amo_op = AMO_NONE;
    assign mem_data_o.way = '0;             // I think this field is only for OpenPiton



// =============================================================================================================
// ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑  SYNTHESIZEABLE CODE    ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑
// ↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓  NON-SYNTHESIZABLE CODE ↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓
// =============================================================================================================



    // ****************************
    // Assertions
    // ****************************

    //pragma translate_off
    `ifndef VERILATOR

        initial begin
            assert (ariane_pkg::DCACHE_LINE_WIDTH >= riscv::XLEN)
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