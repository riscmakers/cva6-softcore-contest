// ===============================================================================
// Module: 
//  RISC Makers data cache
//
// Description: 
// - Direct mapped
// - Writeback, write allocate
//   - on writebacks, only the CPU requested data is written back to cache, not
//   - the entire cache block
// - Blocking 
//   - On loads, by default we request an entire cache block from main memory
//   - Loads have priority over stores
//   - Memory reads have priority over writebacks
//   - Currently, cache stalls waiting for memory transfers to 
//     complete if a writeback and a read need to occur
//     - Eventually, we will request writebacks and read transfers successively 
//       (back-to-back) via the request port
//     - Possibly using a FIFO so that the requests are sent and 
//       returned in order (or the TIDs could be read)
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
    /* verilator lint_on UNUSED */
    output logic miss_o, // performance counters dont increment in debug mode
    input dcache_req_i_t [2:0] req_ports_i,
    output dcache_req_o_t [2:0] req_ports_o,
    input logic mem_rtrn_vld_i,
    input dcache_rtrn_t mem_rtrn_i,
    output logic mem_data_req_o,
    input logic mem_data_ack_i,
    output dcache_req_t mem_data_o
);

    // *****************************
    // Internal signal declaration
    // *****************************

    // ----- miscellaneous ----
    dcache_state_t current_state_q, next_state_d; // FSM state register
    logic miss_load;  // we missed on a load request (high for 1 clock cycle)
    logic miss_store; // we missed on a store request (high for 1 clock cycle)
    logic bypass_cache; // debugging flag used to test input/output CPU <--> memory interface

    // ----- flags ----
    logic pending_request; // do we have an active request from one of the request ports?
    request_port_select_t current_request_port; // from which port are we currently serving the request?
    logic is_cache_ready_for_request; // can cache can service a new request? i.e. register the input request port data?

    // logic tag_store_compare_done, tag_store_compare_done_neg_q, tag_store_compare_done_pos_q; // flag to know when a tag comparision is done 
    // logic tag_compare_hit; // cache hit
    // logic writeback_flag_d, writeback_flag_q, writeback_flag_en; // set a flag when we need to writeback data in the cache

    // ----- registered request port --------
    // Note: input request ports need to be registered because if we grant a request, the data
    //       changes on the following clock edge. also because the write data is only valid on the
    //       following clock edge, whereas the addresses are valid as soon as a cache request is issued.
    //
    //       finally, if we have a cache miss, we need to remember the address and 
    //       data after the main memory transaction is done 
    dcache_req_i_t req_port_i_d, req_port_i_q; 

    // ----- cache stores -------
    // tag_store_t tag_store;
    // data_store_t data_store;

    // ------ address -------
    riscv::xlen_t req_port_address; // the complete physical address used by output memory request port during load
    // riscv::xlen_t dcache_address; // the complete physical address used by output memory request port during writeback
    //logic [dcache_pkg::DCACHE_CL_IDX_WIDTH-1:0] req_port_block_index; // the current block index bits (indexes into RAM stores)
    logic [dcache_pkg::DCACHE_OFFSET_WIDTH-1:0] req_port_block_offset;// selected byte from cacheblock

    // ******************************
    // Continuous assignment signals
    // ******************************

    // ----- miscellaneous ----
    assign miss_o = miss_store | miss_load; // for Ariane performance counters (active for half a clock cycle)
    assign current_request_port = (req_ports_i_d.data_we) ? STORE_UNIT_PORT : LOAD_UNIT_PORT;
    assign pending_request = req_ports_i[LOAD_UNIT_PORT].data_req | req_ports_i[STORE_UNIT_PORT].data_req

    // Note: req_port_i_d.address_index will always equal the index to the stores.
    //       since we're not writing to any other set in cache, its just the tag that could be different
    // assign dcache_address = {tag_store.data_i.tag, req_port_i_d.address_index}; 
    assign req_port_address = {req_port_i_d.address_tag, req_port_i_d.address_index};

    // this address drops block offset bits. for example, consider the following parameters:
    //              DCACHE_INDEX_WIDTH = 12 bits
    //              DCACHE_CL_IDX_WIDTH = 9 bits
    //              DCACHE_OFFSET_WIDTH = 3 bits
    // so we would select bits 11:3 for the cache block index, and bits 2:0 for the cache block offset
    // assign req_port_block_index = req_port_i_d.address_index[dcache_pkg::DCACHE_INDEX_WIDTH-1:dcache_pkg::DCACHE_OFFSET_WIDTH];

    // select the block offset bits from the input address
    assign req_port_block_offset = req_port_i_d.address_index[dcache_pkg::DCACHE_OFFSET_WIDTH-1:0];

     // since we're only requesting a single memory transfer at a time, we can set this statically to 0
    // assign mem_data_o.tid = wt_cache_pkg::CACHE_ID_WIDTH'b1;
    assign mem_data_o.tid = 1;

    // tag comparision is done if we have the toggle flip-flop outputs in phase.
    // we need 2 flip flops changing state 90 degrees out of phase for the case where we have 
    // back to back CPU loads. If we only had 1 tag done flag, on the following clock edge we would
    // think the tag store comparision was done, although in reality it finishes on the falling clock edge 
    // assign tag_store_compare_done = (tag_store_compare_done_neg_q == tag_store_compare_done_pos_q) ? 1'b1 : 1'b0;

    // cache hit
    // assign tag_compare_hit = ((tag_store.data_i.tag == req_port_i_d.address_tag) && (tag_store.data_i.valid));

    assign mem_data_o.nc = (~enable_i) | (~ariane_pkg::is_inside_cacheable_regions(ArianeCfg, {{{64-ariane_pkg::DCACHE_TAG_WIDTH-ariane_pkg::DCACHE_INDEX_WIDTH}{1'b0}}, req_port_i_d.address_tag, {ariane_pkg::DCACHE_INDEX_WIDTH{1'b0}}}));
    assign bypass_cache = 1'b1; // force the cache to be bypassed all the time... lets see if we can complete the program


    // ****************************
    // Instantiated modules
    // ****************************

    // Note: currently, we only read/write to the cache set the CPU requests.
    //       i.e., we aren't accessing other cache locations to perform, for example,
    //       prefetching. that's why the store addresses are connected to the ports' block indexes

    // Data store (RAM)
    // dcache_data_store #(
    //     .DATA_WIDTH(dcache_pkg::DCACHE_LINE_WIDTH),
    //     .NUM_WORDS(dcache_pkg::DCACHE_NUM_WORDS)
    // ) i_dcache_data_store (
    //     .clk_i(clk_i),
    //     .en_i(data_store.enable),
    //     .we_i(data_store.write_enable),
    //     .rst_ni(rst_ni),
    //     .write_byte_i(data_store.byte_enable),
    //     .addr_i(req_port_block_index),
    //     .wdata_i(data_store.data_o),
    //     .rdata_o(data_store.data_i)  
    // );

    // // Tag store (RAM)
    // dcache_tag_store #(
    //     .DATA_WIDTH(dcache_pkg::DCACHE_TAG_STORE_DATA_WIDTH), 
    //     .NUM_WORDS(dcache_pkg::DCACHE_NUM_WORDS)
    // ) i_dcache_tag_store (
    //     .clk_i(clk_i),
    //     .en_i(tag_store.enable),
    //     .we_i(tag_store.write_enable),
    //     .rst_ni(rst_ni),
    //     .addr_i(req_port_block_index),
    //     .wdata_i(tag_store.data_o),
    //     .bit_en_i(tag_store.bit_enable),      
    //     .rdata_o(tag_store.data_i)
    // );

    // *******************************
    // Request port selection
    // *******************************

    // -------- mux selected request port data ---------
    // Note: if we have a cache hit, we can't use the registered req_port_i_q signals
    //       because we need to read address data before these signals are registered.
    //       tag comparision occurs on the falling edge of the clock after 
    //       an input request is sent. the request port data is still available 
    //       on that first clock edge (thats also why we grab the input to the register).
    //       thus, we mux the appropiate port from req_ports_i with the req_port_i_q. 

    always_comb begin: register_request_port_input
         // don't change register state if we are currently serving a request or if
         // it's unnecessary (there is no active request) since that saves energy
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
        // in these states we could service another request (because we have a blocking cache)
        if (current_state_q == IDLE || current_state_q == LOAD_CACHE_HIT) begin
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

        // *******************************
        // Default values for all signals
        // *******************************
        // Note: its judicious to choose default signal values that are less likely
        //       to be modified by the FSM, to save a bit of bit switching dynamic energy 
        //       (pun intended). We also might consider setting these default values to
        //       other signals, for example data_store.data_o could be default connected to
        //       mem_data_o.data. This might reduce the number of bit switching overall.
        
        // ----- miscellaneous ----
        next_state_d = current_state_q; 
        miss_load = 1'b0;  
        miss_store = 1'b0;
        // writeback_flag_d = 1'b0; // since default value == 0, we just need to enable writeback_flag_en to clear writeback flag
        // writeback_flag_en = 1'b0; // settings this to 0 allows the write-back flag to maintain state

        // ------ input/output request ports ------
        req_ports_o[STORE_UNIT_PORT].data_gnt = 1'b0;
        req_ports_o[LOAD_UNIT_PORT].data_gnt = 1'b0;
        req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b0;
        req_ports_o[LOAD_UNIT_PORT].data_rdata = '0;

        // ------ main memory request port ------
        // Note: for the MNIST application, roughly 94% of all memory instructions are Loads
        //       thus, we should expect this to be the default request type
        mem_data_req_o = 1'b0;
        mem_data_o.rtype = wt_cache_pkg::DCACHE_LOAD_REQ;
        mem_data_o.size = dcache_pkg::CACHE_MEM_REQ_SIZE_CACHEBLOCK; // value is more likely because there are more loads than stores

        mem_data_o.data = '0;    // Registering this might save energy?
        mem_data_o.paddr = '0;   

        // ------ tag store ------
        // tag_store.enable = 1'b0;           // disabled by default to help with energy consumption
        // tag_store.write_enable = 1'b0;     // value is more likely because there should be less cache misses than there are tag comparisions
        // tag_store.bit_enable.valid = 1'b1; // value is more likely because no cache coherency protocol is implemented?
        // tag_store.bit_enable.dirty = 1'b1; // value is more likely because write-back cache? 
        // tag_store.bit_enable.tag = '0;     // Not sure which value is more likely 
        // tag_store.data_o = '0;     

        // ------ data store -------
        // data_store.enable = 1'b0;          // disabled by default to help with energy consumption
        // data_store.write_enable = 1'b0;    // value is more likely because there are more loads than stores
        // data_store.data_o = '0;            // Not sure if cache block reads from memory are more likely than CPU stores
        // data_store.byte_enable = '0;  

        // ------- unused ---------
        // Note: issue with continuous and procedural assignment?
        //       statically set to 0 because the store unit isn't expecting data output from the cache
        //       issue: Variable 'req_ports_o' written by continuous and procedural assignments
        //       so that's why this is commented out
        req_ports_o[PTW_PORT] = '0; // PTW (as well as MMU) is not implemented
        req_ports_o[STORE_UNIT_PORT].data_rvalid = 1'b0;

        // **********************
        // State logic
        // **********************
        case(current_state_q)

            IDLE : begin
                if (pending_request) begin
                    req_ports_o[current_request_port].data_gnt = 1'b1;  // grant the request
                    service_request();  
                end
            end

            // LOAD_CACHE_HIT : begin
            //     // be careful here! as we could potentially service another request, we need to use
            //     // registered request port data. For the moment, req_port_block_offset only selects
            //     // bits from req_port_i_d, so I'll need to add a helper function that selects the appropiate
            //     // bits, or I could directly write the expression
            //     req_ports_o[LOAD_UNIT_PORT].data_rdata = cache_block_to_cpu_word(
            //                                                 data_store.data_i,
            //                                                 req_port_i_q.address_index[dcache_pkg::DCACHE_OFFSET_WIDTH-1:0],
            //                                                 req_port_i_q.data_size);
            //     req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1; // let the load unit know the data is available
            //     service_request(); // free to service another request
            // end

            // STORE_CACHE_HIT: begin
            //     // Note: if we are in this state, we are going to write into the data store on the 
            //     //       rising clock edge. To do that however, we need the previous request's address_index bits.
            //     //       thus after a store cache hit, we can't immediately service another request.
            //     //       we would need another port to the SRAM, or we could add some functionality
            //     //       to service a hit to the same address (index). Or we could add a write buffer...
            //     //       
            //     //       However we could serve another serve another request so long as its not a load.
            //     //       In this case we simply have to use the req_port_i_q data since it was clocked in before
            //     //       and verify that the current request is not going to be a load request that will hit (otherwise
            //     //       we will have to stall either this cache hit store or that cache hit load)
            //     //
            //     //       If it's a cache miss, because we're not writing to the data store, we could finish this store
            //     tag_store.enable = 1'b0;        // dirty bit was set (if it was cleared before request) in IDLE

            //     data_store.write_enable = 1'b1; // set to write
            //     data_store.enable = 1'b1;       // write will occur on following rising clock edge
            //     data_store.data_o = cpu_word_to_cache_block(
            //                             req_port_i_d.data_wdata,
            //                             req_port_block_offset,
            //                             req_port_i_d.data_size);
            //     data_store.byte_enable = cpu_to_cache_byte_enable(
            //                                 req_port_i_d.data_be, 
            //                                 req_port_block_offset,
            //                                 req_port_i_d.data_size);
            //     next_state_d = IDLE;
            // end 

            // STORE_CACHE_MISS: begin

            //      // if writeback flag is not active, we can write allocate, write dirty bit and exit
            //     if (!writeback_flag_q) begin // flag was registered in previous clock edge

            //         // tag store
            //         tag_store.enable = 1'b1;
            //         tag_store.write_enable = 1'b1;

            //         tag_store.bit_enable.dirty = 1'b1;
            //         tag_store.bit_enable.valid = 1'b1;
            //         tag_store.bit_enable.tag = '1;

            //         tag_store.data_o.dirty = 1'b1; 
            //         tag_store.data_o.valid = 1'b1;
            //         tag_store.data_o.tag = req_port_i_d.address_tag;


            //         // data store write
            //         data_store.enable = 1'b1;
            //         data_store.write_enable = 1'b1;
            //         data_store.data_o = cpu_word_to_cache_block(
            //                                 req_port_i_d.data_wdata,
            //                                 req_port_block_offset,
            //                                 req_port_i_d.data_size);
            //         data_store.byte_enable = cpu_to_cache_byte_enable(
            //                                     req_port_i_d.data_be, 
            //                                     req_port_block_offset,
            //                                     req_port_i_d.data_size);

            //         next_state_d = IDLE; // wait till next clock cycle to serve a request, because we're currently writing to stores
            //     end

            //     // otherwise, we have to writeback first, then write the CPU data to cache
            //     // Note: since we're here, we *could* write the new tags the CPU is giving us
            //     //        while the data is being transferred from or to main memory. 
            //     //        however, since we will update the "dirty" bit anyway after the transfer is done, 
            //     //        lets just wait to do that. this avoids us having to buffer the 
            //     //        tag that we need to writeback (and that is being replaced).
            //     //        also note that in order to remember that we need to write CPU data to the cache 
            //     //        after this writeback, we won't clear the writeback flag.
            //     else begin 

            //         tag_store.enable = 1'b0; // we'll use this after the writeback

            //         // start memory transfer
            //         mem_data_o.rtype = wt_cache_pkg::DCACHE_STORE_REQ;
            //         mem_data_o.size = {1'b0, req_port_i_d.data_size}; // because we only need to writeback data that was replaced by CPU

            //         mem_data_o.paddr = cpu_to_memory_address(
            //                             dcache_address, 
            //                             mem_data_o.size); // because this is a writeback with tag bits from cache

            //         mem_data_o.data = cache_block_to_cpu_word(
            //                             data_store.data_i, // we're writing back cache data, not CPU data 
            //                             req_port_block_offset,
            //                             req_port_i_d.data_size);
            //         mem_data_req_o = 1'b1;

            //         // has main memory acknowledged our store request?
            //         next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_WRITEBACK_DONE : WAIT_MEMORY_WRITEBACK_ACK;
            //     end
            // end             

            // WAIT_MEMORY_READ_ACK : begin
            //     // Note: I don't know if we have to keep the request signals/data in the same state
            //     //       as they were when we issued the request to main memory... i.e. registered? 
            //     next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_READ_DONE : WAIT_MEMORY_READ_ACK;
            // end 

            // WAIT_MEMORY_WRITEBACK_ACK : begin
            //     next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_WRITEBACK_DONE : WAIT_MEMORY_WRITEBACK_ACK;
            // end 

            WAIT_MEMORY_BYPASS_ACK : begin
                // keep the request active until it is acknowledged by main memory
                mem_data_o.rtype = (current_request_port == STORE_UNIT_PORT) ? DCACHE_STORE_REQ : DCACHE_LOAD_REQ;
                mem_data_o.size = {1'b0, req_port_i_d.data_size};
                mem_data_o.paddr = cpu_to_memory_address(
                                    req_port_address, 
                                    mem_data_o.size);
                mem_data_o.data = req_port_i_d.data_wdata;
                mem_data_req_o = 1'b1;

                next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_BYPASS_DONE : WAIT_MEMORY_BYPASS_ACK;
            end 

            WAIT_MEMORY_BYPASS_DONE : begin
                if ( mem_rtrn_vld_i && 
                   ( mem_rtrn_i.rtype == ( (current_request_port == STORE_UNIT_PORT) ? DCACHE_STORE_ACK : DCACHE_LOAD_ACK ) ) ) begin // main memory finished writeback

                    // let the CPU know that the data is available from main memory (if it is a load)
                    req_ports_o[current_request_port].data_rdata = cache_block_to_cpu_word(
                                                                    mem_rtrn_i.data,
                                                                    req_port_block_offset,
                                                                    req_port_i_d.data_size);
                    if (current_request_port == LOAD_UNIT_PORT) begin
                        req_ports_o[current_request_port].data_rvalid = 1'b1; // stores do not need to be ack'ed
                    end

                    next_state_d = IDLE;
                end 
            end 

            // WAIT_MEMORY_WRITEBACK_DONE : begin
            //     if ((mem_rtrn_vld_i) && (mem_rtrn_i.rtype == DCACHE_STORE_ACK)) begin // main memory finished writeback
            //         // not much to do here, because we do writeback after load.
            //         // however if we had to do a store (CPU) and a writeback (memory), now we need to write 
            //         // the CPU store data into the cache and mark tag bits as valid and dirty.
            //         // the writeback_flag indicates whether or not we have to still perform a store

            //         if (writeback_flag_q) begin
            //             // tag store
            //             tag_store.enable = 1'b1;
            //             tag_store.write_enable = 1'b1;

            //             tag_store.bit_enable.dirty = 1'b1;
            //             tag_store.bit_enable.valid = 1'b1;
            //             tag_store.bit_enable.tag = '1;

            //             tag_store.data_o.dirty = 1'b1; 
            //             tag_store.data_o.valid = 1'b1;
            //             tag_store.data_o.tag = req_port_i_d.address_tag;

            //             // data store write
            //             data_store.enable = 1'b1;
            //             data_store.write_enable = 1'b1;
            //             data_store.data_o = cpu_word_to_cache_block(
            //                                     req_port_i_d.data_wdata,
            //                                     req_port_block_offset,
            //                                     req_port_i_d.data_size);
            //             data_store.byte_enable = cpu_to_cache_byte_enable(
            //                                         req_port_i_d.data_be, 
            //                                         req_port_block_offset,
            //                                         req_port_i_d.data_size);                        
            //         end

            //         // clear the writeback flag, now, as we're done
            //         writeback_flag_d = 1'b0;
            //         writeback_flag_en = 1'b1;
                    
            //         next_state_d = IDLE;
            //     end 
            // end 

            // WAIT_MEMORY_READ_DONE : begin 
            //     if ((mem_rtrn_vld_i) && (mem_rtrn_i.rtype == wt_cache_pkg::DCACHE_LOAD_ACK)) begin // main memory finished read

            //         // let the CPU know that the data is available from main memory
            //         req_ports_o[LOAD_UNIT_PORT].data_rdata = cache_block_to_cpu_word(
            //                                                     mem_rtrn_i.data,
            //                                                     req_port_block_offset,
            //                                                     req_port_i_d.data_size);
            //         req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1;

            //         // do we still need to writeback? (i.e. did we get a CPU load request and cache block to be replaced is dirty?)
            //         if (writeback_flag_q) begin

            //             // clear the writeback flag, now, as we're servicing it
            //             writeback_flag_d = 1'b0;
            //             writeback_flag_en = 1'b1;

            //             // start memory transfer
            //             mem_data_o.rtype = wt_cache_pkg::DCACHE_STORE_REQ;

            //             // note adding an extra bit in front of the data size because data_size field
            //             // is only 2 bits wide, and can't request anything more than a word, whereas the
            //             // memory request port can fetch a whole cacheblock 
            //             mem_data_o.size = {1'b0, req_port_i_d.data_size}; // only writeback data that was replaced by CPU
            //             mem_data_o.paddr = cpu_to_memory_address(
            //                                 dcache_address, 
            //                                 mem_data_o.size); // because this is a writeback with tag bits from cache
            //             mem_data_o.data = cache_block_to_cpu_word(
            //                                 data_store.data_i, // we're writing back cache data, not CPU data 
            //                                 req_port_block_offset,
            //                                 req_port_i_d.data_size);
            //             mem_data_req_o = 1'b1;

            //             // has main memory acknowledged our store request?
            //             next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_WRITEBACK_DONE : WAIT_MEMORY_WRITEBACK_ACK;

            //         end
            //         else begin
            //             // nope, we didn't need to writeback so we can return to IDLE
            //             // Note: we could perhaps structure the code to service a new request here, but currently because 
            //             //       certain mem_data_o fields use data in the registered req_port_i_d data, we have to wait until
            //             //       the cache is in a request serviceable state
            //             next_state_d = IDLE;
            //         end 

            //         // before leaving this state, we need to write the block we just got from main memory to cache
    
            //         // tag store
            //         tag_store.enable = 1'b1;
            //         tag_store.write_enable = 1'b1;

            //         tag_store.bit_enable.dirty = 1'b1; 
            //         tag_store.bit_enable.valid = 1'b1;
            //         tag_store.bit_enable.tag = '1;

            //         tag_store.data_o.dirty = 1'b0; // cleared because we just got clean data from memory
            //         tag_store.data_o.valid = 1'b1;
            //         tag_store.data_o.tag = req_port_i_d.address_tag;

            //         // data store write
            //         data_store.enable = 1'b1;
            //         data_store.write_enable = 1'b1;
            //         data_store.data_o = mem_rtrn_i.data;
            //         data_store.byte_enable = '1; // main memory fetches us an entire cache block
        
            //     end 
            // end

        endcase
    end

    // ***************************************
    // Module-level functions
    // ***************************************

    function automatic void service_request();

            // do we have a non cacheable address? 
            if (bypass_cache) begin
                mem_data_o.rtype = (current_request_port == STORE_UNIT_PORT) ? DCACHE_STORE_REQ : DCACHE_LOAD_REQ;
                mem_data_o.size = {1'b0, req_port_i_d.data_size};
                mem_data_o.paddr = cpu_to_memory_address(
                                    req_port_address, 
                                    mem_data_o.size);
                mem_data_o.data = req_port_i_d.data_wdata;
                mem_data_req_o = 1'b1;

                // did we get a load acknowledgement? if not, wait for one
                next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_BYPASS_DONE : WAIT_MEMORY_BYPASS_ACK;
            end 

            // Commented out to just test memory communication
            // else begin
            //     // Note: enable tag comparision: cache hit result will be available on the next falling clock edge.
            //     //       because this state won't change until the next rising clock edge, we can check for a cache hit.
            //     //       be careful though, we have to wait until the comparision is done before continuing (falling edge)
            //     //       otherwise we could be writing to the tag_store while we're trying read it (cache store miss)
            //     tag_store.write_enable = 1'b0; // read tags
            //     tag_store.enable = 1'b1;

            //     // are we done with the tag comparision?
            //     if (tag_store_compare_done) begin

            //         // did we get a cache block hit?
            //         if (tag_compare_hit) begin
            //             if (current_request_port == CPU_REQ_LOAD) begin 
            //                 tag_store.enable = 1'b0;        // tags, valid and dirty bits don't need to change
            //                 data_store.write_enable = 1'b0; // set to read
            //                 data_store.enable = 1'b1;       // data will be available on the next rising clock edge
            //                 next_state_d = LOAD_CACHE_HIT;
            //             end 
            //             else begin
            //                 // since it's a store, we need to check the dirty bit 
            //                 // (i.e. are we dirtying a cache block for the first time?)
            //                 if (!tag_store.data_i.dirty) begin 
            //                     // tag write occurs on next rising clock edge
            //                     tag_store.enable = 1'b1;
            //                     tag_store.write_enable = 1'b1;
            //                     tag_store.bit_enable.dirty = 1'b1;
            //                     tag_store.bit_enable.valid = 1'b0;
            //                     tag_store.bit_enable.tag = '0;
            //                     tag_store.data_o.dirty = 1'b1; 
                                
            //                 end
            //                 // otherwise, we're done with the tag store
            //                 else begin 
            //                     tag_store.enable = 1'b0;
            //                 end 
            //                 // we can't handle this in this state (clock cycle) because the store 
            //                 // data is not yet available from the request port
            //                 next_state_d = STORE_CACHE_HIT;
            //             end
            //         end
            //         // nope - we have a cache miss
            //         else begin 
            //             // we need to check if we have to writeback
            //             if (tag_store.data_i.valid & tag_store.data_i.dirty) begin 
            //                 writeback_flag_d = 1'b1;
            //                 writeback_flag_en = 1'b1;
            //             end
            //             // missed on a CPU load
            //             if (current_request_port == CPU_REQ_LOAD) begin
            //                 miss_load = 1'b1; 

            //                 // we don't need to use the tag store anymore because we won't writeback 
            //                 // until after the request (that we missed on) is served by main memory
            //                 tag_store.enable = 1'b0; 

            //                 // immediately request a main memory transaction
            //                 mem_data_o.rtype = wt_cache_pkg::DCACHE_LOAD_REQ;
            //                 mem_data_o.size = dcache_pkg::CACHE_MEM_REQ_SIZE_CACHEBLOCK;
            //                 mem_data_o.paddr = cpu_to_memory_address(
            //                                     req_port_address, 
            //                                     mem_data_o.size);
            //                 mem_data_req_o = 1'b1;

            //                 // did we get a load acknowledgement? if not, wait for one
            //                 next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_READ_DONE : WAIT_MEMORY_READ_ACK;

            //             end 
            //             // missed on a CPU store
            //             else begin
            //                 miss_store = 1'b1; 
            //                 // we can't immediately perform a memory request because
            //                 // the store data is not yet available from the request port
            //                 next_state_d = STORE_CACHE_MISS;
            //             end     
            //         end 
            //     end 
            // end 
    endfunction


    // ***************************************
    // Sequential logic (flip-flops, latches)
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

    // always_ff @(posedge(clk_i)) begin: update_writeback_flag
    //     if (!rst_ni) begin
    //         writeback_flag_q <= '0;
    //     end 
    //     else begin
    //         if (writeback_flag_en) begin
    //             writeback_flag_q <= writeback_flag_d;
    //         end 
    //     end
    // end

    // --------- Tag comparision flags ---------

    // Note: a possible optimization is to avoid toggling if we don't need to perform 
    //       a tag comparision. it's a bit tricky though, because if there is a tag miss, 
    //       need to make sure the two pos/neg flags have opposite values (otherwise the next tag comparision 
    //       will not work).
    //
    //       finally, upon reset, we want to assure that the two toggle flags are opposite values,
    //       otherwise a tag comparision would be "finished" when the two flags are out of phase 
    //       (that could also work, but the combinatorial tag_store_compare_done flag would need to be changed)

    // always_ff @(negedge(clk_i)) begin: update_tag_store_comparision_flag_neg
    //     if (!rst_ni) begin
    //         tag_store_compare_done_neg_q <= '0;
    //     end 
    //     else begin
    //         tag_store_compare_done_neg_q <= ~tag_store_compare_done_neg_q;
    //     end
    // end

    // always_ff @(posedge(clk_i)) begin: update_tag_store_comparision_flag_pos
    //     if (!rst_ni) begin
    //         tag_store_compare_done_pos_q <= '1;
    //     end 
    //     else begin
    //         tag_store_compare_done_pos_q <= ~tag_store_compare_done_pos_q;
    //     end
    // end

    // *************************************
    // Unused module ports (not implemented)
    // *************************************
    assign flush_ack_o = 1'b1;      // flush is not implemented, but let CPU know it is always performed
    assign wbuffer_empty_o = 1'b1;  // write buffer is not implemented, so its always "empty"
    assign wbuffer_not_ni_o = 1'b1; // not sure about what I should set this to, 
                                    // but in 'ariane.sv' there is this: 'assign dcache_commit_wbuffer_not_ni = 1'b1;' for the std_dcache 
                                    // and in load_unit.sv this needs to == 1 in WAIT_WB_EMPTY state
    assign amo_resp_o = '0;         // might need to set this to always acknowledged?
    assign mem_data_o.amo_op = AMO_NONE; // AMOs are not implemented
    assign mem_data_o.way = '0; // I think this field is only for OpenPiton


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
        initial begin
            assert (dcache_pkg::DCACHE_LINE_WIDTH >= riscv::XLEN)
            else begin $warning("Data cache line width is smaller than the processor word length"); end
        end

        assert property (@(posedge clk_i)(req_ports_i[LOAD_UNIT_PORT].data_we == 0))
            else begin $warning("Load unit port data_we is not always == 0"); end

        assert property (@(posedge clk_i)(req_ports_i[STORE_UNIT_PORT].data_we == 1))
            else begin $warning("Store unit port data_we is not always == 1"); end

        // assert property (@(posedge clk_i)(is_cache_servicing_request == req_ports_o[current_request_port].data_gnt))
        //     else begin $warning("Request granted at an inappropiate moment"); end

        // Note: these asserts fail at the beginning of the simulation ***** later on they work
        // read it like: AT the clock edge, not AFTER the clock edge passes. thus ==
        // assert property (@(posedge clk_i)(tag_store_compare_done_neg_q == tag_store_compare_done_pos_q))
        //     else begin $warning("Tag store comparision toggle flops are in phase at pos clock edge "); end
        // // read it like: AT the clock edge, not AFTER the clock edge passes. thus !=
        // assert property (@(negedge clk_i)(tag_store_compare_done_neg_q != tag_store_compare_done_pos_q))
        //     else begin $warning("Tag store comparision toggle flops are out of phase at neg clock edge "); end


    `endif
    //pragma translate_on

endmodule