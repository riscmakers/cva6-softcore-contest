package dcache_pkg;

    localparam int unsigned CONFIG_L1D_SIZE    = 4*1024; // assures that index width is 12 bits
    localparam int unsigned DCACHE_SET_ASSOC   = 1; // direct mapped
    localparam int unsigned DCACHE_INDEX_WIDTH = $clog2(CONFIG_L1D_SIZE / DCACHE_SET_ASSOC); // in bit, contains also offset width 
    localparam int unsigned DCACHE_TAG_WIDTH   = riscv::PLEN-DCACHE_INDEX_WIDTH; // in bit
    localparam int unsigned DCACHE_LINE_WIDTH  = 128; // in bit
    localparam DCACHE_OFFSET_WIDTH     = $clog2(dcache_pkg::DCACHE_LINE_WIDTH/8);
    localparam DCACHE_NUM_WORDS        = 2**(dcache_pkg::DCACHE_INDEX_WIDTH-DCACHE_OFFSET_WIDTH);
    localparam DCACHE_CL_IDX_WIDTH     = $clog2(DCACHE_NUM_WORDS);// excluding byte offset
    

    // *************************************
    // Types
    // *************************************

    typedef enum {
        IDLE,                       // wait for a CPU memory request
        LOAD_CACHE_HIT,             // need a clock cycle to output data from cache data store and to set rvalid flag
        WAIT_MEMORY_READ_ACK,       // wait for main memory to acknowledge read (load) request
        WAIT_MEMORY_READ_DONE,      // wait for main memory to return with read (load) data
        WAIT_MEMORY_WRITEBACK_ACK,  // wait for main memory to acknowledge writeback (store) request
        WAIT_MEMORY_WRITEBACK_DONE, // wait for main memory to finish writeback (store) request
        WAIT_MEMORY_BYPASS_ACK,     // wait for non-cacheable (I/O space) request to be ack'ed
        WAIT_MEMORY_BYPASS_DONE     // wait for non-cacheable (I/O space) request to be completed
    } dcache_state_t;

    // dcache has multiple request ports (3 by default)
    // these numbers correspond to which unit controls the port
    typedef enum logic [1:0] {
        PTW_PORT=0,
        LOAD_UNIT_PORT=1,     
        STORE_UNIT_PORT=2  
    } request_port_select_t;

    // tag store structure for input/output data
    typedef struct packed {
        logic valid;     // valid bit
        logic dirty;     // dirty bit
        logic [dcache_pkg::DCACHE_TAG_WIDTH-1:0] tag; // actual tag store data
    } tag_store_data_t;

    // tag store structure for bit enable (same as above because its bit enable)
    typedef tag_store_data_t tag_store_bit_enable_t;

    typedef struct packed {
        logic enable; // is the tag store enabled? 
        logic write_enable; // are we reading from or writing to tag store?
        tag_store_data_t data_i; // contains all tag data read from tag store
        tag_store_data_t data_o; // contains all tag data written to tag store
        tag_store_bit_enable_t bit_enable; // vector that enables individual write bits for tag store
    } tag_store_t;

    typedef struct packed {
        logic enable; // is the data store enabled?
        logic write_enable; // are we reading from or writing to data store?
        logic [dcache_pkg::DCACHE_LINE_WIDTH-1:0] data_i; // contains all data read from data store
        logic [dcache_pkg::DCACHE_LINE_WIDTH-1:0] data_o; // contains all data written to data store
        logic [dcache_pkg::DCACHE_LINE_WIDTH/8-1:0] byte_enable; // vector that enables individual write bytes for data store
    } data_store_t;

    // for buffering a writeback request, and thus allowing loads/stores from CPU to overwrite store data before writeback occurs
    typedef struct packed {
        logic flag; // do we need to writeback ?
        riscv::xlen_t data; // we can only writeback word sizes 
        logic [riscv::PLEN-1:0] address; 
    } writeback_t;

    // *************************************
    // Constants
    // *************************************

    // meaningful names for mem_data_o.size (main memory request)
    localparam MEMORY_REQUEST_SIZE_ONE_BYTE = 3'b000;    // load/store byte (XLEN/4)
    localparam MEMORY_REQUEST_SIZE_TWO_BYTES = 3'b001;   // load/store half word (XLEN/2)
    localparam MEMORY_REQUEST_SIZE_FOUR_BYTES = 3'b010;  // load/store word (XLEN)
    localparam MEMORY_REQUEST_SIZE_EIGHT_BYTES = 3'b011; // load/store double word (XLEN*2)
    localparam MEMORY_REQUEST_SIZE_CACHEBLOCK = 3'b111;  // DCACHE_LINE_WIDTH

    // meaningful names for req_ports_i.data_size (CPU request)
    localparam CPU_REQUEST_SIZE_BYTE = 2'b00;           // load/store byte (XLEN/4)
    localparam CPU_REQUEST_SIZE_TWO_BYTES = 2'b01;      // load/store half word (XLEN/2)
    localparam CPU_REQUEST_SIZE_FOUR_BYTES = 2'b10;     // load/store word (XLEN)
    localparam CPU_REQUEST_SIZE_EIGHT_BYTES = 2'b11;    // load/store double word (XLEN*2) ***not supported with xlen == 32***

    localparam int unsigned DCACHE_TAG_STORE_DATA_WIDTH = $bits(tag_store_data_t); // tag width plus valid and dirty bit
    // tag store output data (ordering): {valid bit,  dirty bit,  tag data}
    //                                      (MSB)      (MSB-1)     (MSB-2)...
    parameter int unsigned TAG_STORE_DIRTY_BIT_POSITION = dcache_pkg::DCACHE_TAG_WIDTH; // MSB-1
    parameter int unsigned TAG_STORE_VALID_BIT_POSITION = TAG_STORE_DIRTY_BIT_POSITION+1; // MSB

    // *************************************
    // Functions
    // *************************************

    // for converting the CPU physical address to an AXI memory request address, or a cache block address, depending on transfer size
    function automatic logic [riscv::PLEN-1:0] cpu_to_memory_address(
        input logic [riscv::PLEN-1:0] cpu_address,
        input logic [2:0]  data_transfer_size
    );
        automatic logic [riscv::PLEN-1:0] memory_address = cpu_address;

        unique case (data_transfer_size)
            MEMORY_REQUEST_SIZE_ONE_BYTE: ; 
            MEMORY_REQUEST_SIZE_TWO_BYTES: memory_address[0:0] = '0; 
            MEMORY_REQUEST_SIZE_FOUR_BYTES: memory_address[1:0] = '0; 
            MEMORY_REQUEST_SIZE_EIGHT_BYTES: memory_address[2:0] = '0; 
            MEMORY_REQUEST_SIZE_CACHEBLOCK: memory_address[dcache_pkg::DCACHE_OFFSET_WIDTH-1:0] = '0;
            default: ;
        endcase

        return memory_address;
    endfunction

    // for extracting a CPU word from either the mem_rtrn_i.data field or from the data store
    function automatic riscv::xlen_t cache_block_to_cpu_word (
        input logic [dcache_pkg::DCACHE_LINE_WIDTH-1:0] cache_block,
        input logic [riscv::PLEN-1:0] cpu_address,
        input logic is_data_noncacheable
    );

        // RHS generates only 1 bit, whereas we are expecting 2 bits on LHS. I think we should make LHS 1 bit, but double check that the function works first
        automatic logic [dcache_pkg::DCACHE_OFFSET_WIDTH-riscv::XLEN_ALIGN_BYTES-1:0] cache_block_noncacheable_offset = cpu_address[2];

        automatic logic [dcache_pkg::DCACHE_OFFSET_WIDTH-riscv::XLEN_ALIGN_BYTES-1:0] cache_block_offset = 
                                                (is_data_noncacheable) ? cache_block_noncacheable_offset : 
                                                                        cpu_address[dcache_pkg::DCACHE_OFFSET_WIDTH-1:riscv::XLEN_ALIGN_BYTES];

        automatic riscv::xlen_t cpu_word = cache_block[cache_block_offset*riscv::XLEN +: riscv::XLEN];

        return cpu_word;
    endfunction


    // for writing to data store, either after a full cache block load from main memory or by the CPU for a store hit
    function automatic logic [15:0] to_byte_enable16(
        input logic [3:0] offset,
        input logic [2:0] size
    );
    logic [15:0] be;
    be = '0;
    unique case(size)
        3'b000:   be[offset]       = '1; // byte
        3'b001:   be[offset +:2 ]  = '1; // hword
        3'b010:   be[offset +:4 ]  = '1; // word
        3'b011:   be[offset +:8 ]  = '1; // dword
        3'b111:   be               = '1; // cache block
        default: be                = '1; // by default, cache block
    endcase // size
    return be;
    endfunction : to_byte_enable16

endpackage
