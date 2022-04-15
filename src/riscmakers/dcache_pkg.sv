package dcache_pkg;

    localparam int unsigned CONFIG_L1D_SIZE    = 32*1024;
    localparam int unsigned DCACHE_SET_ASSOC   = 8; // Must be between 4 to 64
    localparam int unsigned DCACHE_INDEX_WIDTH = $clog2(CONFIG_L1D_SIZE / DCACHE_SET_ASSOC);  // in bit, contains also offset width
    localparam int unsigned DCACHE_TAG_WIDTH   = riscv::PLEN-DCACHE_INDEX_WIDTH;  // in bit
    localparam int unsigned DCACHE_LINE_WIDTH  = 128; // in bit (max support up to 512 bit cache lines)
    localparam DCACHE_OFFSET_WIDTH     = $clog2(ariane_pkg::DCACHE_LINE_WIDTH/8);
    localparam DCACHE_NUM_WORDS        = 2**(ariane_pkg::DCACHE_INDEX_WIDTH-DCACHE_OFFSET_WIDTH);
    localparam DCACHE_CL_IDX_WIDTH     = $clog2(DCACHE_NUM_WORDS);// excluding byte offset
    localparam DCACHE_NUM_BANKS        = ariane_pkg::DCACHE_LINE_WIDTH/64;
    localparam DCACHE_NUM_BANKS_WIDTH  = $clog2(DCACHE_NUM_BANKS);

    localparam DCACHE_DATA_WIDTH       = 64;
    localparam int unsigned DCACHE_TAG_STORE_DATA_WIDTH = ariane_pkg::DCACHE_TAG_WIDTH + 2; // tag width plus valid and dirty bit

    // dcache has multiple request ports (3 by default)
    // these numbers correspond to which unit controls the port
    localparam int unsigned PTW_PORT = 0;
    localparam int unsigned LOAD_UNIT_PORT = 1; // from Load/Store unit
    localparam int unsigned STORE_UNIT_PORT = 2; // from Load/Store unit

    // tag store output data (ordering): {valid bit,  dirty bit,  tag data}
    //                                      (MSB)      (MSB-1)     (MSB-2)...
    parameter int unsigned TAG_STORE_DIRTY_BIT_POSITION = DCACHE_TAG_WIDTH; // MSB-1
    parameter int unsigned TAG_STORE_VALID_BIT_POSITION = TAG_STORE_DIRTY_BIT_POSITION+1; // MSB

    // meaningful names for mem_data_o.size
    localparam int unsigned MEM_REQ_SIZE_ONE_BYTE = 3'b000;
    localparam int unsigned MEM_REQ_SIZE_TWO_BYTES = 3'b001;
    localparam int unsigned MEM_REQ_SIZE_FOUR_BYTES = 3'b010;
    localparam int unsigned MEM_REQ_SIZE_EIGHT_BYTES = 3'b011;
    localparam int unsigned MEM_REQ_SIZE_CACHELINE = 3'b111; // not sure if the max here is 16 or 32 bytes, or more (64 bytes?)

    // meaningful names for req_ports_i.data_size
    localparam int unsigned MEM_REQ_TYPE_BYTE = 2'b00; // load/store byte
    localparam int unsigned MEM_REQ_TYPE_HALF_WORD = 2'b01; // load/store half word
    localparam int unsigned MEM_REQ_TYPE_WORD = 2'b10; // load/store word
    localparam int unsigned MEM_REQ_TYPE_DOUBLE_WORD = 2'b11; // load/store double word

    // memory request type (Load Unit => Load or Store Unit => Store)
    typedef enum logic {
        CPU_REQ_LOAD=0,     // Load/Store flag = 0 when there is a Load (because of data_we signal in req_port struct)
        CPU_REQ_STORE=1     // Load/Store flag = 1 when there is a Store (because of data_we signal in req_port struct)
    } memory_request_t;

    // tag store structure for input/output data
    typedef struct packed {
        logic valid;     // valid bit
        logic dirty;     // dirty bit
        logic [ariane_pkg::DCACHE_TAG_WIDTH-1:0] tag; // actual tag store data
    } tag_store_t;

    // tag store structure for bit enable
    typedef struct packed {
        logic valid;     // valid bit
        logic dirty;     // dirty bit
        logic [ariane_pkg::DCACHE_TAG_WIDTH-1:0] tag; // actual tag store data
    } tag_store_bit_enable_t;




endpackage
