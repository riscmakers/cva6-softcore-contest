package dcache_pkg;


    // eventually change these to be specific to ariane. From the CPU perspective, I think
    // it is forced to use 12 bit index widths, whereas we can do a simple translation
    // and use whatever index we want (from the main memory perspective its the same)
    // I think that if we're given an address, the cache can intrepet it however it pleases
    // it can thus have a different cache index width, its irrelevant to the outside world
    // for now keep same values, just assure that index width = 12, because the width corresponds
    // to a field type size in dcache_req_i_t, we have to respect that (later we can concatenate that
    // to a long vector and reintrepet the address)
    localparam int unsigned CONFIG_L1D_SIZE    = 4*1024; // assures that index width is 12 bits
    localparam int unsigned DCACHE_SET_ASSOC   = 1; // direct mapped
    // seems that index width has to be = 12 here, because of the virtual mapping 
    // see wt_dcache: cache index width can be maximum 12bit since VM uses 4kB pages
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
        LOAD_CACHE_HIT,             // need a clock cycle to output data from cache data store
        STORE_CACHE_HIT,            // need a clock cycle after request for store unit to output write data
        STORE_CACHE_MISS,           // need a clock cycle after request for store unit to output write data
        WAIT_MEMORY_READ_ACK,       // wait for main memory to acknowledge read (load) request
        WAIT_MEMORY_READ_DONE,      // wait for main memory to return with read (load) data
        WAIT_MEMORY_WRITEBACK_ACK,  // wait for main memory to acknowledge writeback (store) request
        WAIT_MEMORY_WRITEBACK_DONE, // wait for main memory to finish writeback (store) request
        WAIT_MEMORY_BYPASS_ACK,     // request is not cached
        WAIT_MEMORY_BYPASS_DONE     // request is not cached
    } dcache_state_t;

    // memory request type (Load Unit => Load or Store Unit => Store)
    typedef enum logic [1:0] {
        CPU_REQ_NONE=0, // no active request
        CPU_REQ_LOAD=1,     
        CPU_REQ_STORE=2  
    } memory_request_t;

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
        logic write_enable; // are we reading or writing to data store?
        logic [dcache_pkg::DCACHE_LINE_WIDTH-1:0] data_i; // contains all data read from data store
        logic [dcache_pkg::DCACHE_LINE_WIDTH-1:0] data_o; // contains all data written to data store
        logic [dcache_pkg::DCACHE_LINE_WIDTH/8-1:0] byte_enable; // vector that enables individual write bytes for data store
    } data_store_t;

    // *************************************
    // Constants
    // *************************************

    // meaningful names for mem_data_o.size (main memory request)
    localparam CACHE_MEM_REQ_SIZE_ONE_BYTE = 3'b000; // load/store byte (XLEN/4)
    localparam CACHE_MEM_REQ_SIZE_TWO_BYTES = 3'b001; // load/store half word (XLEN/2)
    localparam CACHE_MEM_REQ_SIZE_FOUR_BYTES = 3'b010; // load/store word (XLEN)
    localparam CACHE_MEM_REQ_SIZE_EIGHT_BYTES = 3'b011; // load/store double word (XLEN*2)
    localparam CACHE_MEM_REQ_SIZE_CACHEBLOCK = 3'b111; // DCACHE_LINE_WIDTH

    // meaningful names for req_ports_i.data_size (CPU request)
    localparam CPU_MEM_REQ_TYPE_BYTE = 2'b00; // load/store byte (XLEN/4)
    localparam CPU_MEM_REQ_TYPE_TWO_BYTES = 2'b01; // load/store half word (XLEN/2)
    localparam CPU_MEM_REQ_TYPE_FOUR_BYTES = 2'b10; // load/store word (XLEN)
    localparam CPU_MEM_REQ_TYPE_EIGHT_BYTES = 2'b11; // load/store double word (XLEN*2)

    localparam int unsigned DCACHE_TAG_STORE_DATA_WIDTH = $bits(tag_store_data_t); // tag width plus valid and dirty bit
    // tag store output data (ordering): {valid bit,  dirty bit,  tag data}
    //                                      (MSB)      (MSB-1)     (MSB-2)...
    parameter int unsigned TAG_STORE_DIRTY_BIT_POSITION = dcache_pkg::DCACHE_TAG_WIDTH; // MSB-1
    parameter int unsigned TAG_STORE_VALID_BIT_POSITION = TAG_STORE_DIRTY_BIT_POSITION+1; // MSB

    // *************************************
    // Functions
    // *************************************

    // --------------- cpu <==> cache addressing translation -----------------

    // if we have cache block data and we only need a single word from it
    // depending on the size, we need to select 8, 16, or 32 bits ! but 
    // where are we going to grab 32 bits from (for example)? need  to make
    // sure the physical address block offset is masked appropiately 
    function automatic riscv::xlen_t cache_block_to_cpu_word (
        input logic [dcache_pkg::DCACHE_LINE_WIDTH-1:0] cache_block,
        input logic [dcache_pkg::DCACHE_OFFSET_WIDTH-1:0] cpu_block_offset,
        input logic [1:0] data_transfer_size
    );
        automatic riscv::xlen_t word = '0; // otherwise sim shows unknown values on the data output vector;
        automatic logic [dcache_pkg::DCACHE_OFFSET_WIDTH-1:0] cache_block_offset = cpu_to_cache_block_offset(cpu_block_offset, data_transfer_size);

        unique case(data_transfer_size)
            CPU_MEM_REQ_TYPE_BYTE: word[7:0] = cache_block[cache_block_offset*8 +: 8];  // byte
            CPU_MEM_REQ_TYPE_TWO_BYTES: word[(riscv::XLEN/2)-1:0] = cache_block[cache_block_offset*8 +: riscv::XLEN/2]; // hword
            CPU_MEM_REQ_TYPE_FOUR_BYTES:  word[riscv::XLEN-1:0] = cache_block[cache_block_offset*8 +: riscv::XLEN]; // word 
            CPU_MEM_REQ_TYPE_EIGHT_BYTES: word[riscv::XLEN-1:0] = cache_block[cache_block_offset*8 +: riscv::XLEN]; // double word (not supported with 32 bit processor)!!
        endcase

        return word;
  endfunction

    // if we have the CPU data, we need to place this data somewhere within the cache block
    // but depending on the size, we need to write 8, 16, or 32 bits! we need to make sure we
    // write the the appropiate location! if the size is 1 byte, we can ANYWHERE within the cache block
    // (8 bit granularity) but if its a 4 byte transfer, then we can select only 4 different starting locations
    // because now we have a 32 bit granularity
    // note that offset 
    function automatic logic [dcache_pkg::DCACHE_LINE_WIDTH-1:0] cpu_word_to_cache_block (
        input riscv::xlen_t word,
        input logic [dcache_pkg::DCACHE_OFFSET_WIDTH-1:0] cpu_block_offset,
        input logic [1:0] data_transfer_size
    );
        automatic logic [dcache_pkg::DCACHE_LINE_WIDTH-1:0] cache_block = '0; // otherwise sim shows unknown values on the data output vector
        automatic logic [dcache_pkg::DCACHE_OFFSET_WIDTH-1:0] cache_block_offset = cpu_to_cache_block_offset(cpu_block_offset, data_transfer_size);

        unique case(data_transfer_size)
            CPU_MEM_REQ_TYPE_BYTE: cache_block[cache_block_offset*8 +: 8] = word[7:0];  // byte
            CPU_MEM_REQ_TYPE_TWO_BYTES: cache_block[cache_block_offset*8 +: riscv::XLEN/2] = word[(riscv::XLEN/2)-1:0]; // hword
            CPU_MEM_REQ_TYPE_FOUR_BYTES:  cache_block[cache_block_offset*8 +: riscv::XLEN] = word[riscv::XLEN-1:0]; // word 
            CPU_MEM_REQ_TYPE_EIGHT_BYTES: cache_block[cache_block_offset*8 +: riscv::XLEN] = word[riscv::XLEN-1:0]; // double word (not supported with 32 bit processor)!!
        endcase

        return cache_block;
  endfunction

  // align the physical address to the specified size:
  // for example:
  // a cache line width of 128 bits, with a word length of 32 bits
  // if the size is 1 byte (8 bits) then the block address offset is unchanged
  // (it specifies 8 bit granularity of the cache data)
  // if the size is 2 bytes (16 bits) the block address offset corresponds to 
  // accessing half word locations. thus the granularity increased by 2, and thus
  // there is a superflous bit in the index (we set this to 0).
  // ... etc.
  function automatic logic [dcache_pkg::DCACHE_OFFSET_WIDTH-1:0] cpu_to_cache_block_offset(
        input logic [dcache_pkg::DCACHE_OFFSET_WIDTH-1:0] cpu_block_offset,
        input logic [1:0]  data_transfer_size
    );
        automatic logic [dcache_pkg::DCACHE_OFFSET_WIDTH-1:0] cache_block_offset = cpu_block_offset;

        unique case (data_transfer_size)
            CPU_MEM_REQ_TYPE_BYTE: ; // each bit of the block offset address corresponds to a byte offset, so dont clear any bits
            CPU_MEM_REQ_TYPE_TWO_BYTES: cache_block_offset[0:0] = '0; // each bit of the block offset address corresponds to a half word offset, so remove the first bit
            CPU_MEM_REQ_TYPE_FOUR_BYTES: cache_block_offset[1:0] = '0; // each bit of the block offset address corresponds to a word offset, so remove the first 2 bits 
            CPU_MEM_REQ_TYPE_EIGHT_BYTES: cache_block_offset[2:0] = '0; // each bit of the block offset address corresponds to a double offset, so remove the first 3 bits
            default: ;
        endcase

        return cache_block_offset;
    endfunction

  // similiar to above, except this is used when we are requesting data from main memory
  function automatic logic [riscv::XLEN-1:0] cpu_to_memory_address(
        input logic [riscv::XLEN-1:0] cpu_address,
        input logic [2:0]  data_transfer_size
    );
        automatic logic [riscv::XLEN-1:0] memory_address = cpu_address;

        unique case (data_transfer_size)
            CACHE_MEM_REQ_SIZE_ONE_BYTE: ; // each bit of the block offset address corresponds to a byte offset, so dont clear any bits
            CACHE_MEM_REQ_SIZE_TWO_BYTES: memory_address[0:0] = '0; // each bit of the block offset address corresponds to a half word offset, so remove the first bit
            CACHE_MEM_REQ_SIZE_FOUR_BYTES: memory_address[1:0] = '0; // each bit of the block offset address corresponds to a word offset, so remove the first 2 bits 
            CACHE_MEM_REQ_SIZE_EIGHT_BYTES: memory_address[2:0] = '0; // each bit of the block offset address corresponds to a double offset, so remove the first 3 bits
            CACHE_MEM_REQ_SIZE_CACHEBLOCK: memory_address[dcache_pkg::DCACHE_OFFSET_WIDTH-1:0] = '0; // cache line size, so the block offset address is not used
            default: ;
        endcase

        return memory_address;
    endfunction

    // !!!!!!!!!!!!! NEED TO ADD FUNCTION THAT DETERMINES BYTE ENABLE VECTOR FOR CACHE BLOCK
    // DEPENDING ON DATA SIZE TRANSFER..... !!!!!!!
    // for example, if we are transfering 1 byte, where in the cache line are we writing, etc. So this does something similiar to
    // the function above except its specific to the byte enables. depending on size we will byte enable only select bytes.

    // we can simply use the byte_enable that was included in the req_i_data.data_be and depending on the offset, we shift that 
    // the bottom line is fine I think, except for the req_port_block_offset. this needs to be the physically aligned one
    // that is changed depending on the size !
    //data_store.byte_enable = ( { {(dcache_pkg::DCACHE_LINE_WIDTH/8-riscv::XLEN/8){1'b0}} , req_port_i_d.data_be } )  << req_port_block_offset;

    // question, can I do ( { {dcache_pkg::DCACHE_LINE_WIDTH/8{1'b0, req_port_i_d.data_be}} ) ? no i dont think so
    function automatic logic [(2**dcache_pkg::DCACHE_OFFSET_WIDTH)-1:0] cpu_to_cache_byte_enable (
        input logic [(riscv::XLEN/8)-1:0] byte_enable_cpu,
        input logic [dcache_pkg::DCACHE_OFFSET_WIDTH-1:0] cpu_block_offset,
        input logic [1:0]  data_transfer_size
    );
        automatic logic [(2**dcache_pkg::DCACHE_OFFSET_WIDTH)-1:0] byte_enable_cache;
        automatic logic [dcache_pkg::DCACHE_OFFSET_WIDTH-1:0] cache_block_offset = cpu_to_cache_block_offset(cpu_block_offset, data_transfer_size);

        byte_enable_cache = ( { {((2**dcache_pkg::DCACHE_OFFSET_WIDTH)-riscv::XLEN/8){1'b0}} , byte_enable_cpu } ) << cache_block_offset;
        
        return byte_enable_cache;
    endfunction

endpackage
