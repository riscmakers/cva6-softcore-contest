// *****************************
// RISC Makers data cache
// 
// Simple cache system
// - Direct mapped
// - Write back, write-allocate
// Input/output details in dcache_description.md
// *****************************

import ariane_pkg::*; 
import wt_cache_pkg::*;
import dcache_pkg::*;

module dcache 
#(
    parameter logic [CACHE_ID_WIDTH-1:0] RdAmoTxId = 1,     // not used (AMOs are not enabled)
    parameter ariane_pkg::ariane_cfg_t ArianeCfg = ariane_pkg::ArianeDefaultConfig
) 
(
    input logic clk_i,   
    input logic rst_ni,  
    input logic enable_i,  
    input logic flush_i,   
    output logic flush_ack_o,   
    output logic miss_o,   
    output logic wbuffer_empty_o,   
    output logic wbuffer_not_ni_o,  
    input amo_req_t amo_req_i,
    output amo_resp_t amo_resp_o,
    input dcache_req_i_t [2:0] req_ports_i,
    output dcache_req_o_t [2:0] req_ports_o,
    input logic mem_rtrn_vld_i,
    input dcache_rtrn_t mem_rtrn_i,
    output logic mem_data_req_o,
    input logic mem_data_ack_i,
    output dcache_req_t mem_data_o
);

    // ******************
    // Internal types
    // ******************
    typedef enum {
        IDLE,               // wait for a CPU memory request
        COMPARE_TAG,        // compare cache tags. Need to wait at least 1 clock cycle for 
                            // valid tags to be generated from Load/Store unit
        WAIT_MEMORY_READ,   // wait for main memory to return with load data
        WAIT_MEMORY_WRITE   // wait for main memory to acknowledge store
    } dcache_state_t;

    // ******************
    // Internal signals
    // ******************
    logic miss_store;        // we missed on a Store request
    logic miss_load;         // we missed on a Load request
    dcache_state_t current_state, next_state; // FSM state register
    int unsigned selected_request_port; // mux select for request port, to be handled by FSM
    logic data_store_enable;
    logic tag_store_enable;
    logic tag_store_write_enable;

    logic [wt_cache_pkg::DCACHE_CL_IDX_WIDTH-1:0] selected_cacheblock_index;    // the current cacheblock index bits (indexes into SRAM stores)

    tag_store_t tag_store_data_i; // contains all tag data read from tag store
    tag_store_t tag_store_data_o; // contains all tag data written to tag store
    tag_store_bit_enable_t tag_store_bit_enable; // vector that enables individual bit writes for tag store


    logic [ariane_pkg::DCACHE_TAG_WIDTH] selected_address_tag_d, selected_address_tag_q;
    logic [ariane_pkg::DCACHE_INDEX_WIDTH-1:0] selected_address_index_d, selected_address_index_q;
    logic [7:0] selected_byte_enable_d, selected_byte_enable_q; // hard coded sizes, because these are fixed in ariane_pkg.sv
    logic [1:0] selected_data_size_d, selected_data_size_q; // hard coded sizes, because these are fixed in ariane_pkg.sv
    logic [63:0] selected_data_d, selected_data_q; // hard coded sizes, because these are fixed in ariane_pkg.sv
    // note: these are currently hard coded, but thalesgroup recently did a commit on openhwgroup making these
    // configurable (32 bit or 64 bit)
    // either I need to implement this commit, or change the store widths to adapt to these hard coded sizes
    // if DATA_WIDTH is set to 64 its fine though


    // ****************************
    // Continous assignment signals
    // ****************************
    assign miss_o = miss_store | miss_load; // for Ariane performance counters

    // this address drops block offset bits. for example:
    // DCACHE_INDEX_WIDTH = 12 bits
    // DCACHE_CL_IDX_WIDTH = 9 bits
    // DCACHE_OFFSET_WIDTH = 3 bits
    // so we select bits 11:3 for the cache block index, and bits 2:0 for the cache block offset
    assign selected_cacheblock_index = selected_address_index_q[ariane_pkg::DCACHE_INDEX_WIDTH-1:wt_cache_pkg::DCACHE_OFFSET_WIDTH];

    // dont forget to get the offset !!!! If our cache lines are 64 bits for example, we need to select a single byte
    // of information from there! Now I will say, is the byte enable 
    // assign address_off_d = (req_port_o.data_gnt) ? req_port_i.address_index[DCACHE_OFFSET_WIDTH-1:0] : address_off_q;
    // !!!!!! so if we have a cache line size of 64 bits, when we write to the data store, the upper bits have to be
    // set to enabled or disabled. We need to know where to write the data. this is the block offset! 
    // although Im just not sure if the byte enable is equal to the block offset (I think it is)

    // statically set to 0 because this port will never output any data (its only for storing!)
    assign req_ports_o[STORE_UNIT_PORT].data_rvalid = 1'b0;
    assign req_ports_o[STORE_UNIT_PORT].data_rdata = '0;

    // only select the tag bits and ignore valid/dirty bits from tag store output
    assign tag_store_tag_data = tag_store_data_i[ariane_pkg::DCACHE_TAG_WIDTH-1:0];

    // select valid/dirty bits from tag store output
    assign tag_store_valid_bit_i = tag_store_data_i[dcache_pkg::TAG_STORE_VALID_BIT_POSITION-1]; // '-1' because 0 indexed
    assign tag_store_dirty_bit_i = tag_store_data_i[dcache_pkg::TAG_STORE_DIRTY_BIT_POSITION-1]; // '-1' because 0 indexed

    // concat. valid and dirty bits with actual tags to write
    assign tag_store_data_o = {tag_store_valid_bit_o, tag_store_dirty_bit_o, selected_address_tag_q};

    // we will always write a full tag, so enable all these bits
    assign tag_store_bit_enable.tag = '1;

    // ****************************
    // Instantiated modules
    // ****************************

    // Data store (RAM)
    dcache_data_store #(
        .DATA_WIDTH(dcache_pkg::DCACHE_DATA_WIDTH),
        .NUM_WORDS(wt_cache_pkg::DCACHE_NUM_WORDS)
    ) i_dcache_data_store (
        .clk_i(clk_i),
        .en_i(data_store_enable),
        .we_i(req_ports_i[selected_request_port].data_we), // the load or the store unit could use this
        .write_byte_i(selected_byte_enable_q),  // currently, only the store unit will control which bytes are written
        .addr_i(selected_cacheblock_index),  // the load or the store unit could use this
        .wdata_i(req_ports_i[STORE_UNIT_PORT].data_wdata), // currently, only the store unit controls the store's input data
        .rdata_o(req_ports_o[LOAD_UNIT_PORT].data_rdata)   // currently, only the load unit uses the store's output data
    );

    // Tag store (RAM)
    dcache_tag_store #(
        .DATA_WIDTH(dcache_pkg::DCACHE_TAG_STORE_DATA_WIDTH), 
        .NUM_WORDS(wt_cache_pkg::DCACHE_NUM_WORDS)
    ) i_dcache_tag_store (
        .clk_i(clk_i),
        .en_i(tag_store_enable),
        .we_i(tag_store_write_enable),
        .addr_i(selected_cacheblock_index),
        .wdata_i(tag_store_data_o),
        .bit_en_i(tag_store_bit_enable),      
        .rdata_o(tag_store_data_i)
    );


    // *******************************
    // Cache finite state machine
    // *******************************

    always_comb begin

        // *******************************
        // Default values for all signals
        // *******************************
        next_state = current_state; // blocking assignment, wait until state changes

        // Set Load Unit and Store Unit request port defaults (interface with CPU)
        req_ports_o[STORE_UNIT_PORT].data_gnt = 1'b0;
        req_ports_o[LOAD_UNIT_PORT].data_gnt = 1'b0;
        req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b0;

        // Set memory request port defaults (interface with AXI adapter/main memory)
        // Note: currently DCACHE_LOAD_REQ and DCACHE_STORE_REQ are the only valid request types
        mem_data_req_o = 1'b0;

        // for the MNIST application, roughly 94% of all memory instructions are Loads
        // thus, we should expect this to be the default request type
        mem_data_o.rtype = DCACHE_LOAD_REQ;
        mem_data_o.size = MEM_REQ_SIZE_CACHELINE; // by default, we're fetching an entire cache block
        mem_data_o.tid = '0;
        mem_data_o.nc = 1'b0;
        mem_data_o.data = '0;
        mem_data_o.paddr = '0; // make sure this is memory aligned by using wt_cache_pkg::paddrSizeAlign
                               // for example: wt_cache_pkg::paddrSizeAlign(tmp_paddr, mem_data_o.size);

        miss_load = 1'b0;
        miss_store = 1'b0;

        tag_store_write_enable = 1'b0;
        tag_store_bit_enable.valid = 1'b1; // I think it's more likely that we're setting the valid bit rather than clearing it
                                           // (because no cache coherency protocol implemented)
        tag_store_bit_enable.dirty = 1'b0; // I think it's more likely that we're clearing the dirty bit rather than setting it 
                                           // (because write-back cache)



        // ****************
        // State logic
        // ****************
        case(current_state)
            IDLE : begin
                // do we have a Load request? (Load Unit has higher priority than Store Unit)
                if (req_ports_i[LOAD_UNIT_PORT].data_req) begin
                    selected_request_port = LOAD_UNIT_PORT;      // mux select the Load Unit port        
                    req_ports_o[LOAD_UNIT_PORT].data_gnt = 1'b1; // grant Load request
                    next_state = COMPARE_TAG;                    // check if we have a Load cache hit in the next state
                    
                    // save request port data
                    selected_address_tag_d <= req_ports_i[LOAD_UNIT_PORT].address_tag;
                    selected_address_index_d <= req_ports_i[LOAD_UNIT_PORT].address_index;
                    selected_byte_enable_d <= req_ports_i[LOAD_UNIT_PORT].data_be;
                    selected_data_size_d <= req_ports_i[LOAD_UNIT_PORT].data_size;
                            
                end
                // do we have a Store request?
                else if (req_ports_i[STORE_UNIT_PORT].data_req) begin
                    selected_request_port = STORE_UNIT_PORT;        // mux select the Store Unit port
                    req_ports_o[STORE_UNIT_PORT].data_gnt = 1'b1;   // grant Store request
                    next_state = COMPARE_TAG;                       // check if we have a Store cache hit in the next state

                    // save request port data
                    selected_address_tag_d <= req_ports_i[STORE_UNIT_PORT].address_tag;
                    selected_address_index_d <= req_ports_i[STORE_UNIT_PORT].address_index;
                    selected_byte_enable_d <= req_ports_i[STORE_UNIT_PORT].data_be;
                    selected_data_size_d <= req_ports_i[STORE_UNIT_PORT].data_size;
                    selected_data_d <= req_ports_i[STORE_UNIT_PORT].data_wdata; // only the store unit will give data

                end 
            end

            COMPARE_TAG : begin
                // when the MMU is disabled, input tags should be valid as soon as a request is made

                // enable tag comparision: cache hit result will be performed on the next falling clock edge
                tag_store_enable = 1'b1;

                // do we have a cache hit?
                if (tag_store_tag_data == selected_address_tag_q && tag_store_valid_bit_i) begin
                    // yes, so enable the data store (we're either going to read or write)
                    data_store_enable = 1'b1;

                    // if its a load (write enable is high), output data to port
                    // if its a store (write enable is low), write data to cache
    
                    // data store output will be available on the next rising clock edge
                    req_ports_o[selected_request_port].data_rvalid = 1'b1;

                    // !!! BE CAREFUL !!!
                    // !!! double check the requestor does not latch the data until the next rising clock edge
                    // !!! otherwise, they will latch the wrong data store data
                    // !!! I think this is the case, since in load_store_unit.sv, the data_rvalid gets propagated to
                    // !!! the signal ld_value, and eventually to 
                    // !!! an output pipeline shift register, which "should" latch on the following clock edge
                end 

                else begin
                    // nope - we have a cache miss
                    if (req_ports_i[selected_request_port].data_we) begin
                        miss_store = 1'b1;
                    end else
                        miss_load = 1'b1;
                    end 
                end 

            end

        endcase
    end

    // update state register and request port data
    // we need to save selected_request_port data in case we have a cache miss
    always_ff @(posedge(clk_i)) begin
        if (!rst_ni) begin
            current_state <= IDLE;
            selected_address_tag_q <= '0;
            selected_address_index_q <= '0;
            selected_byte_enable_q <= '0;
            selected_data_size_q <= '0;
            selected_data_d <= '0;
        end
        else begin
            current_state <= next_state;
            selected_address_tag_q <= selected_address_tag_d;
            selected_address_index_q <= selected_address_index_d;
            selected_byte_enable_q <= selected_byte_enable_d;
            selected_data_size_q <= selected_data_size_d;
            selected_data_q <= selected_data_d;
        end
    end




    // *************************************
    // Unused module ports (not implemented)
    // *************************************
    assign flush_ack_o = 1'b0;      // flush is not implemented
    assign wbuffer_empty_o = 1'b1;  // write buffer is not implemented, so its always "empty"
    assign wbuffer_not_ni_o = 1'b1; // not sure about what I should set this to, but in 'ariane.sv' there is this: 'assign dcache_commit_wbuffer_not_ni = 1'b1;'
    assign amo_resp_o = '0;
    assign req_ports_o[PTW_PORT] = '0; // PTW (as well as MMU) is not implemented
    assign mem_data_o.amo_op = AMO_NONE; // AMOs are not implemented

    // ***********************
    // Unused input signals
    // ***********************
    //
    // from cache_subsystem/wt_axi_adapter.sv: 
    // - remote invalidations are not supported yet (this needs a cache coherence protocol)
    // as a result, the entire invalidation vector is unused:
    // mem_rtrn_i.inv




// ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑  SYNTHESIZEABLE CODE   ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑
//
//
// ↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓ NON-SYNTHESIZABLE CODE ↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓


    // ****************************
    // Assertions
    // ****************************

    //pragma translate_off
    `ifndef VERILATOR

        // TODO: 
        // - check that only DCACHE_STORE_REQ and DCACHE_LOAD_REQ are asserted
        // - check that no AMO requests are generated (not implemented)
        // - check that no flush requests are generated (not implemented)
        // - check that the MMU is disabled/no PTW requests are generated (not implemented)
        // - assure that either a cache store miss or cache load miss is active (mutually exclusive)

        assert property (@(posedge clk_i)(req_ports_i[LOAD_UNIT_PORT].data_we == 0))
            else begin $error("Load unit port data_we is not always == 0"); $stop(); end

        assert property (@(posedge clk_i)(req_ports_i[STORE_UNIT_PORT].data_we == 1))
            else begin $error("Store unit port data_we is not always == 1"); $stop(); end
        
        assert property (@(posedge clk_i)(req_ports_o[STORE_UNIT_PORT].data_rvalid == 0))
            else begin $error("Store unit port data_rvalid is not always == 0"); $stop(); end


    `endif
    //pragma translate_on

endmodule