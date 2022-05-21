import wt_cache_pkg::*;

package riscmakers_pkg;

    // *************************************
    // Types
    // *************************************

    // dcache has multiple request ports (3 by default)
    // these numbers correspond to which unit controls the port
    typedef enum logic [1:0] {
        PTW_PORT=0,
        LOAD_UNIT_PORT=1,     
        STORE_UNIT_PORT=2  
    } request_port_select_t;

    // for buffering a writeback request, and thus allowing loads/stores from CPU to overwrite store data before writeback occurs
    typedef struct packed {
        logic flag; // do we need to writeback ?
        logic [ariane_pkg::DCACHE_LINE_WIDTH-1:0] data; // we can only writeback word sizes, so to transfer an entire cache block we need to loop through this array
        logic [riscv::PLEN-1:0] address; 
    } writeback_t;

    // *************************************
    // Tag stores
    // *************************************

    // tag store structure for input/output data
    typedef struct packed {
        logic valid;     // valid bit
        logic dirty;     // dirty bit
        logic [ariane_pkg::DCACHE_TAG_WIDTH-1:0] tag; // actual tag store data
    } dcache_tag_store_data_t;

    typedef struct packed {
        logic valid;     // valid bit
        logic dirty;     // dirty bit
        logic tag;       // only 1 bit here, because it indicates whether or not the tag should be updated (there are no partial tag updates)
    } dcache_tag_store_bit_enable_t;

    typedef struct packed {
        logic enable; // is the tag store enabled? 
        logic write_enable;
        dcache_tag_store_data_t data_i; // contains all tag data read from tag store
        dcache_tag_store_data_t data_o; // contains all tag data written to tag store
        dcache_tag_store_bit_enable_t bit_enable; // vector that indicates which fields of the tag store will be write enabled
        logic [wt_cache_pkg::DCACHE_CL_IDX_WIDTH-1:0] address;
    } dcache_tag_store_t;


    typedef struct packed {
        logic valid;     // valid bit
        logic [ariane_pkg::ICACHE_TAG_WIDTH-1:0] tag; // actual tag store data
    } icache_tag_store_data_t;

    typedef struct packed {
        logic valid;     // valid bit
        logic tag;       // only 1 bit here, because it indicates whether or not the tag should be updated (there are no partial tag updates)
    } icache_tag_store_bit_enable_t;

    typedef struct packed {
        logic enable; // is the tag store enabled? 
        logic write_enable;
        icache_tag_store_data_t data_i; // contains all tag data read from tag store
        icache_tag_store_data_t data_o; // contains all tag data written to tag store
        icache_tag_store_bit_enable_t bit_enable; // vector that indicates which fields of the tag store will be write enabled
        logic [wt_cache_pkg::ICACHE_CL_IDX_WIDTH-1:0] address;
    } icache_tag_store_t;


    // *************************************
    // Byte aligning for tag store
    // *************************************

    // for interfacing with Xilinx BRAM blocks. Each field takes up a byte multiple of bits, and thus can be byte enabled
    // Xilinx BRAMs have a minimum byte enable size of 8 bits, so align any size to this
    // example:
    // unaligned = 19 => + 7 = 26
    // floor(26/8) = 3 => * 8 = 24
    // aligned = 24, and thus aligned to the nearest byte
    function automatic int unsigned bram_byte_align_int(int unsigned unaligned);
        automatic int unsigned aligned = ((unaligned+7)/8)*8;
        return aligned;
    endfunction

    typedef struct packed {
        logic [7:0] valid;
        logic [7:0] dirty;
        logic [bram_byte_align_int(ariane_pkg::DCACHE_TAG_WIDTH)-1:0] tag;
    } dcache_tag_store_data_byte_aligned_t;

    typedef struct packed {
        logic valid; // 1 bit to enable valid byte write
        logic dirty; // 1 bit to enable dirty byte write 
        logic [(bram_byte_align_int(ariane_pkg::DCACHE_TAG_WIDTH)/8)-1:0] tag; // x bits to enable tag byte write
    } dcache_tag_store_byte_enable_t;

    typedef struct packed {
        dcache_tag_store_data_byte_aligned_t data_i;
        dcache_tag_store_data_byte_aligned_t data_o;
        dcache_tag_store_byte_enable_t byte_enable;
    } dcache_tag_store_byte_aligned_t;


    typedef struct packed {
        logic [7:0] valid;
        logic [bram_byte_align_int(ariane_pkg::ICACHE_TAG_WIDTH)-1:0] tag;
    } icache_tag_store_data_byte_aligned_t;

    typedef struct packed {
        logic valid; // 1 bit to enable valid byte write
        logic [(bram_byte_align_int(ariane_pkg::ICACHE_TAG_WIDTH)/8)-1:0] tag; // x bits to enable tag byte write
    } icache_tag_store_byte_enable_t;

    typedef struct packed {
        icache_tag_store_data_byte_aligned_t data_i;
        icache_tag_store_data_byte_aligned_t data_o;
        icache_tag_store_byte_enable_t byte_enable;
    } icache_tag_store_byte_aligned_t;


    // *************************************
    // Data store
    // *************************************

    typedef struct packed {
        logic enable; // is the data store enabled?
        logic write_enable;
        logic [ariane_pkg::DCACHE_LINE_WIDTH-1:0] data_i; // contains all data read from data store
        logic [ariane_pkg::DCACHE_LINE_WIDTH-1:0] data_o; // contains all data written to data store
        logic [ariane_pkg::DCACHE_LINE_WIDTH/8-1:0] byte_enable; // vector that enables individual write bytes for data store
        logic [wt_cache_pkg::DCACHE_CL_IDX_WIDTH-1:0] address;
    } dcache_data_store_t;


    typedef struct packed {
        logic enable; // is the data store enabled?
        logic write_enable;
        logic [ariane_pkg::ICACHE_LINE_WIDTH-1:0] data_i; // contains all data read from data store
        logic [ariane_pkg::ICACHE_LINE_WIDTH-1:0] data_o; // contains all data written to data store
        logic [ariane_pkg::ICACHE_LINE_WIDTH/8-1:0] byte_enable; // vector that enables individual write bytes for data store
        logic [wt_cache_pkg::ICACHE_CL_IDX_WIDTH-1:0] address;
    } icache_data_store_t;


    // *************************************
    // Constants
    // *************************************

    localparam NUMBER_OF_WORDS_IN_DCACHE_BLOCK = ariane_pkg::DCACHE_LINE_WIDTH/riscv::XLEN;
    localparam NUMBER_OF_WORDS_IN_ICACHE_BLOCK = ariane_pkg::ICACHE_LINE_WIDTH/riscv::XLEN;

    // meaningful names for mem_data_o.size (main memory request)
    localparam MEMORY_REQUEST_SIZE_ONE_BYTE = 3'b000;    // load/store byte (XLEN/4)
    localparam MEMORY_REQUEST_SIZE_TWO_BYTES = 3'b001;   // load/store half word (XLEN/2)
    localparam MEMORY_REQUEST_SIZE_FOUR_BYTES = 3'b010;  // load/store word (XLEN)
    localparam MEMORY_REQUEST_SIZE_EIGHT_BYTES = 3'b011; // load/store double word (XLEN*2)
    localparam MEMORY_REQUEST_SIZE_CACHEBLOCK = 3'b111;  // DCACHE_LINE_WIDTH

    // meaningful names for req_ports_i.data_size (CPU request)
    localparam CPU_REQUEST_SIZE_ONE_BYTE = 2'b00;           // load/store byte (XLEN/4)
    localparam CPU_REQUEST_SIZE_TWO_BYTES = 2'b01;      // load/store half word (XLEN/2)
    localparam CPU_REQUEST_SIZE_FOUR_BYTES = 2'b10;     // load/store word (XLEN)
    localparam CPU_REQUEST_SIZE_EIGHT_BYTES = 2'b11;    // load/store double word (XLEN*2) ***not supported with xlen == 32***

    // valid byte + dirty byte + tag bytes (aligned for Xilinx BRAM instanciation)
    // ================================================================================================================
    // example:
    // DCACHE_TAG_STORE_DATA_WIDTH = 40 (so 24 bits for tag field, 8 bits for valid field and 8 bits for dirty field)
    // DCACHE_TAG_STORE_VALID_BIT_POSITION = 40-1-7 = 32 =>  [  -  -  -  -  -  -  -  -  ]
    // (32 is LSB of the last byte)                      ^                    ^ 
    //                                            bit:   39 38 37 36 35 34 33 32
    // DCACHE_TAG_STORE_DIRTY_BIT_POSITION = 32-1-7 = 24 =>                             [  -  -  -  -  -  -  -  -  ]
    // (24 is LSB of the second to last byte)                                       ^                    ^ 
    //                                            bit:                              31 30 29 28 27 26 25 24   
    // =================================================================================================================                   
    localparam int unsigned DCACHE_TAG_STORE_DATA_WIDTH = 8 + 8 + bram_byte_align_int(ariane_pkg::DCACHE_TAG_WIDTH);
    parameter int unsigned DCACHE_TAG_STORE_VALID_BIT_POSITION = (DCACHE_TAG_STORE_DATA_WIDTH-1)-7; // LSB of last byte
    parameter int unsigned DCACHE_TAG_STORE_DIRTY_BIT_POSITION = (DCACHE_TAG_STORE_VALID_BIT_POSITION-1)-7; // LSB of second to last byte

    // for instruction cache, there is no dirty bit, so 8 less bits
    localparam int unsigned ICACHE_TAG_STORE_DATA_WIDTH = 8 + bram_byte_align_int(ariane_pkg::ICACHE_TAG_WIDTH);
    parameter int unsigned ICACHE_TAG_STORE_VALID_BIT_POSITION = (ICACHE_TAG_STORE_DATA_WIDTH-1)-7; // LSB of last byte

    // *************************************
    // Functions
    // *************************************

    // for converting the CPU physical address to an AXI memory request address, or a dcache block address, depending on transfer size
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
            MEMORY_REQUEST_SIZE_CACHEBLOCK: memory_address[wt_cache_pkg::DCACHE_OFFSET_WIDTH-1:0] = '0;
            default: ;
        endcase

        return memory_address;
    endfunction

    // for extracting a CPU word from either the mem_rtrn_i.data field or from the data store
    function automatic riscv::xlen_t dcache_block_to_cpu_word (
        input logic [ariane_pkg::DCACHE_LINE_WIDTH-1:0] cache_block,
        input logic [riscv::PLEN-1:0] cpu_address,
        input logic is_data_noncacheable
    );

        // TODO: RHS generates only 1 bit, whereas we are expecting 2 bits on LHS. I think we should make LHS 1 bit, but double check that the function works first
        automatic logic [wt_cache_pkg::DCACHE_OFFSET_WIDTH-riscv::XLEN_ALIGN_BYTES-1:0] cache_block_noncacheable_offset = cpu_address[2];

        automatic logic [wt_cache_pkg::DCACHE_OFFSET_WIDTH-riscv::XLEN_ALIGN_BYTES-1:0] cache_block_offset = 
                                                (is_data_noncacheable) ? cache_block_noncacheable_offset : 
                                                                        cpu_address[wt_cache_pkg::DCACHE_OFFSET_WIDTH-1:riscv::XLEN_ALIGN_BYTES];

        automatic riscv::xlen_t cpu_word = cache_block[cache_block_offset*riscv::XLEN +: riscv::XLEN];

        return cpu_word;
    endfunction


    // !!!!!!!!!! Needs to be tested !!!!!!!!!!!!!!!
    // for extracting a CPU word from either the mem_rtrn_i.data field or from the data store
    function automatic riscv::xlen_t icache_block_to_cpu_word (
        input logic [ariane_pkg::ICACHE_LINE_WIDTH-1:0] cache_block,
        input logic [riscv::PLEN-1:0] cpu_address,
        input logic is_data_noncacheable
    );

        automatic logic [wt_cache_pkg::ICACHE_OFFSET_WIDTH-riscv::XLEN_ALIGN_BYTES-1:0] cache_block_noncacheable_offset = cpu_address[2];

        automatic logic [wt_cache_pkg::ICACHE_OFFSET_WIDTH-riscv::XLEN_ALIGN_BYTES-1:0] cache_block_offset = 
                                                (is_data_noncacheable) ? cache_block_noncacheable_offset : 
                                                                        cpu_address[wt_cache_pkg::ICACHE_OFFSET_WIDTH-1:riscv::XLEN_ALIGN_BYTES];

        automatic riscv::xlen_t cpu_word = cache_block[cache_block_offset*riscv::XLEN +: riscv::XLEN];

        return cpu_word;
    endfunction


    // for writing to data store, either after a full cache block load from main memory or by the CPU for a store hit
    function automatic logic [(2**wt_cache_pkg::DCACHE_OFFSET_WIDTH)-1:0] dcache_block_byte_enable(
        input logic [wt_cache_pkg::DCACHE_OFFSET_WIDTH-1:0] offset,
        input logic [2:0] size
    );
    logic [(2**wt_cache_pkg::DCACHE_OFFSET_WIDTH)-1:0] be;
    be = '0;
    unique case(size)
        MEMORY_REQUEST_SIZE_ONE_BYTE:       be[offset]       = '1; // byte
        MEMORY_REQUEST_SIZE_TWO_BYTES:      be[offset +:2 ]  = '1; // hword
        MEMORY_REQUEST_SIZE_FOUR_BYTES:     be[offset +:4 ]  = '1; // word
        MEMORY_REQUEST_SIZE_EIGHT_BYTES:    be[offset +:8 ]  = '1; // dword
        MEMORY_REQUEST_SIZE_CACHEBLOCK:     be               = '1; // cache block
        default:                            be               = '1; // by default, cache block
    endcase // size
    return be;
    endfunction : dcache_block_byte_enable


endpackage
