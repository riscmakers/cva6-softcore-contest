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
    dcache_state_t current_state_q, next_state_d;   // FSM state register
    logic [wt_cache_pkg::CACHE_ID_WIDTH-1:0] WrTxId; 

    // ----- flags ----
    logic pending_request;                      // do we have an active request from one of the request ports?
    request_port_select_t current_request_port; // from which port are we currently serving the request?
    logic is_cache_ready_for_request;           // can cache can service a new request? i.e. register the input request port data?

    // ------ request ports ------
    dcache_req_i_t req_port_i_d, req_port_i_q; 

    // ------ address -------
    riscv::xlen_t req_port_address;                                   // the complete physical address used by output memory request port during load

    // ******************************
    // Continuous assignment signals
    // ******************************

    assign current_request_port = (req_port_i_d.data_we) ? STORE_UNIT_PORT : LOAD_UNIT_PORT;
    assign pending_request = req_ports_i[LOAD_UNIT_PORT].data_req | req_ports_i[STORE_UNIT_PORT].data_req;
    assign WrTxId = 2;
    assign req_port_address = {req_port_i_d.address_tag, req_port_i_d.address_index};
    assign mem_data_o.nc = (~enable_i) | (~ariane_pkg::is_inside_cacheable_regions(ArianeCfg, {{{64-ariane_pkg::DCACHE_TAG_WIDTH-ariane_pkg::DCACHE_INDEX_WIDTH}{1'b0}}, req_port_i_d.address_tag, {ariane_pkg::DCACHE_INDEX_WIDTH{1'b0}}}));


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
        miss_o = 1'b0;
        next_state_d = current_state_q; 

        // ------ input/output request ports ------
        req_ports_o[STORE_UNIT_PORT].data_gnt = 1'b0;
        req_ports_o[STORE_UNIT_PORT].data_rdata = '0;
        req_ports_o[LOAD_UNIT_PORT].data_gnt = 1'b0;
        req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b0;
        req_ports_o[LOAD_UNIT_PORT].data_rdata = '0;

        // ------ main memory request port ------
        mem_data_req_o = 1'b0;
        mem_data_o.rtype = wt_cache_pkg::DCACHE_LOAD_REQ;
        mem_data_o.size = dcache_pkg::CACHE_MEM_REQ_SIZE_CACHEBLOCK;
        mem_data_o.data = '0;  
        mem_data_o.paddr = '0;   

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

                    if (!mem_data_o.nc) begin
                        miss_o = 1'b1;
                    end 

                    mem_data_o.rtype    = (current_request_port == STORE_UNIT_PORT) ? DCACHE_STORE_REQ : DCACHE_LOAD_REQ;
                    mem_data_o.tid      = (current_request_port == LOAD_UNIT_PORT) ? RdAmoTxId : WrTxId; 
                    mem_data_o.size     = {1'b0, req_port_i_d.data_size};
                    mem_data_o.paddr    = cpu_to_memory_address(req_port_address, mem_data_o.size);
                    mem_data_o.data     = req_port_i_d.data_wdata;
                    mem_data_req_o      = 1'b1;

                    next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_BYPASS_DONE : WAIT_MEMORY_BYPASS_ACK;

                end
            end

            WAIT_MEMORY_BYPASS_ACK : begin

                if (req_ports_i[LOAD_UNIT_PORT].kill_req) begin
                    next_state_d = IDLE;
                    req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1;
                end 

                // keep the request active until it is acknowledged by main memory
                else begin
                    mem_data_o.rtype    = (current_request_port == STORE_UNIT_PORT) ? DCACHE_STORE_REQ : DCACHE_LOAD_REQ;
                    mem_data_o.tid      = (current_request_port == LOAD_UNIT_PORT) ? RdAmoTxId : WrTxId; 
                    mem_data_o.size     = {1'b0, req_port_i_d.data_size};
                    mem_data_o.paddr    = cpu_to_memory_address(req_port_address, mem_data_o.size);
                    mem_data_o.data     = req_port_i_d.data_wdata;
                    mem_data_req_o      = 1'b1;

                    next_state_d = (mem_data_ack_i) ? WAIT_MEMORY_BYPASS_DONE : WAIT_MEMORY_BYPASS_ACK;
                end 
            end 

            WAIT_MEMORY_BYPASS_DONE : begin

                if (req_ports_i[LOAD_UNIT_PORT].kill_req) begin
                    next_state_d = IDLE;
                    req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1; 
                end 

                else if ( mem_rtrn_vld_i && ( mem_rtrn_i.rtype == ( (current_request_port == STORE_UNIT_PORT) ? DCACHE_STORE_ACK : DCACHE_LOAD_ACK ) ) ) begin
                    if (current_request_port == LOAD_UNIT_PORT) begin
                        req_ports_o[LOAD_UNIT_PORT].data_rdata = cache_block_to_cpu_word(
                                                                        mem_rtrn_i.data,
                                                                        req_port_address,
                                                                        {1'b0, req_port_i_d.data_size});
                        req_ports_o[LOAD_UNIT_PORT].data_rvalid = 1'b1;
                    end

                    next_state_d = IDLE;
                end 
            end 
        endcase
    end


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


    `endif
    //pragma translate_on

endmodule