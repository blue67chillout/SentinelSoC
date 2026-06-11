module fpga_demo_top (
    input  logic clk,
    input  logic rst_n,
    input  logic start_demo,
    
    // Status Outputs (Drive to LEDs on Nexys 4)
    output logic demo_done,
    output logic signature_valid
);

    // --------------------------------------------------------
    // Byte Swap Helper (Fixes Little-Endian requirements)
    // --------------------------------------------------------
    function automatic logic [31:0] bswap(input logic [31:0] v);
        return {v[7:0], v[15:8], v[23:16], v[31:24]};
    endfunction

    // --------------------------------------------------------
    // Internal Wires & Registers
    // --------------------------------------------------------
    logic [15:0] bram_addr;
    logic [31:0] bram_dout;
    
    logic [5:0]  sha_addr;
    logic        sha_wen;
    logic [31:0] sha_wdata;
    logic [31:0] sha_rdata;
    logic        sha_intr;
    
    logic        ed_start;
    logic        ed_done;
    logic        ed_valid;
    
    logic        ed_ext_we;
    logic [4:0]  ed_ext_dest_sel;
    logic [1:0]  ed_data_sel;
    logic [255:0] ed_ext_data_1;

    // Extracted Ed25519 Registers
    logic [511:0] hash_reg;
    logic [255:0] s_reg, r_reg, pubkey_reg;
    logic [31:0]  msg_length;
    logic [31:0]  words_sent;
    logic [4:0]   sha_read_idx;
    logic [3:0]   read_count;

    // --------------------------------------------------------
    // FSM States
    // --------------------------------------------------------
    typedef enum logic [4:0] {
        ST_IDLE,
        ST_READ_LEN,
        ST_WAIT_LEN,
        ST_READ_S_REQ,
        ST_READ_S_ACK,
        ST_CFG_SHA_LEN,
        ST_CFG_SHA_CTRL,
        ST_SHA_FEED_WAIT,
        ST_SHA_FEED_WRITE,
        ST_SHA_BRAM_DELAY,
        ST_WAIT_HASH,
        ST_READ_HASH_REQ,
        ST_READ_HASH_ACK,
        ST_LOAD_REG_S,
        ST_LOAD_REG_R,
        ST_LOAD_REG_A,
        ST_LOAD_REG_HLO,
        ST_LOAD_REG_HHI,
        ST_ED_START,
        ST_ED_WAIT,
        ST_DONE
    } sys_state_t;
    
    sys_state_t state;

    // --------------------------------------------------------
    // Sub-Module Instantiations
    // --------------------------------------------------------
    firmware_bram #(.INIT_FILE("firmware.mem")) u_bram (
        .clk  (clk),
        .addr (bram_addr),
        .dout (bram_dout)
    );

    sha512_top u_sha512 (
        .clk     (clk),
        .rst_n   (rst_n),
        .addr_i  (sha_addr),
        .wr_en_i (sha_wen),
        .wdata_i (sha_wdata),
        .rdata_o (sha_rdata),
        .intr_o  (sha_intr)
    );

    top_ed25519 u_ed25519 (
        .clk             (clk),
        .rst_n           (rst_n),
        .start_verify    (ed_start),
        
        .ext_data_1      (ed_ext_data_1),
        .ext_data_2      (256'd0), 
        .otp_data        (256'd0),
        .data_sel        (ed_data_sel),
        
        .ext_we          (ed_ext_we),        // Added external WE
        .ext_dest_sel    (ed_ext_dest_sel),  // Added external Dest
        
        .verify_done     (ed_done),
        .signature_valid (ed_valid)
    );

    // --------------------------------------------------------
    // Master System Orchestrator FSM
    // --------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_IDLE;
            bram_addr       <= 16'd0;
            sha_addr        <= 6'd0;
            sha_wen         <= 1'b0;
            sha_wdata       <= 32'd0;
            ed_start        <= 1'b0;
            demo_done       <= 1'b0;
            signature_valid <= 1'b0;
            ed_ext_we       <= 1'b0;
            ed_ext_dest_sel <= 5'd0;
            ed_data_sel     <= 2'b00;
        end else begin
            case (state)
                ST_IDLE: begin
                    demo_done <= 1'b0;
                    ed_ext_we <= 1'b0;
                    if (start_demo) begin
                        bram_addr <= 16'd0; 
                        state     <= ST_READ_LEN;
                    end
                end

                ST_READ_LEN: state <= ST_WAIT_LEN; 

                ST_WAIT_LEN: begin
                    msg_length <= bram_dout;
                    bram_addr  <= 16'd1; // Address 1 is Start of S
                    read_count <= 4'd0;
                    state      <= ST_READ_S_REQ;
                end

                // --- 1. Extract Signature S ---
                ST_READ_S_REQ: state <= ST_READ_S_ACK;
                
                ST_READ_S_ACK: begin
                    // Byte-swap to preserve Little Endian
                    s_reg <= {bswap(bram_dout), s_reg[255:32]}; 
                    
                    if (read_count == 7) begin
                        bram_addr <= 16'd9; // Jump to R (Start of SHA hash)
                        state     <= ST_CFG_SHA_LEN;
                    end else begin
                        bram_addr <= bram_addr + 1;
                        read_count <= read_count + 1;
                        state <= ST_READ_S_REQ;
                    end
                end

                // --- 2. Configure SHA-512 ---
                ST_CFG_SHA_LEN: begin
                    sha_addr  <= 6'h32;
                    sha_wdata <= msg_length;
                    sha_wen   <= 1'b1;
                    state     <= ST_CFG_SHA_CTRL;
                end

                ST_CFG_SHA_CTRL: begin
                    sha_addr   <= 6'h20;
                    sha_wdata  <= 32'h03; 
                    sha_wen    <= 1'b1;
                    words_sent <= 32'd0;
                    state      <= ST_SHA_FEED_WAIT;
                end

                // --- 3. Feed BRAM Data & Strip R/PubKey ---
                ST_SHA_FEED_WAIT: begin
                    sha_wen <= 1'b0;
                    sha_addr <= 6'h21; 
                    if (sha_rdata[0] == 1'b1) state <= ST_SHA_FEED_WRITE;
                end

                ST_SHA_FEED_WRITE: begin
                    sha_addr  <= {1'b0, words_sent[4:0]}; 
                    sha_wdata <= bram_dout;               
                    sha_wen   <= 1'b1;
                    
                    // Sneakily capture R and PubKey while feeding SHA
                    if (bram_addr >= 9 && bram_addr <= 16)
                        r_reg <= {bswap(bram_dout), r_reg[255:32]};
                    if (bram_addr >= 17 && bram_addr <= 24)
                        pubkey_reg <= {bswap(bram_dout), pubkey_reg[255:32]};
                    
                    words_sent <= words_sent + 1;
                    bram_addr  <= bram_addr + 1;
                    
                    if (words_sent + 1 == msg_length)
                        state <= ST_WAIT_HASH;
                    else if ((words_sent + 1) % 32 == 0)
                        state <= ST_SHA_FEED_WAIT; 
                    else
                        state <= ST_SHA_BRAM_DELAY; 
                end

                ST_SHA_BRAM_DELAY: begin
                    sha_wen <= 1'b0;
                    state   <= ST_SHA_FEED_WRITE;
                end

                // --- 4. Extract 512-bit Hash ---
                ST_WAIT_HASH: begin
                    sha_wen <= 1'b0;
                    if (sha_intr) begin
                        sha_read_idx <= 5'd0;
                        state        <= ST_READ_HASH_REQ;
                    end
                end

                ST_READ_HASH_REQ: begin
                    sha_addr <= 6'h22 + sha_read_idx; 
                    state    <= ST_READ_HASH_ACK;
                end

                ST_READ_HASH_ACK: begin
                    // Byte-swap AND shift into MSB for proper Little-Endian formatting
                    hash_reg <= {bswap(sha_rdata), hash_reg[511:32]};
                    
                    if (sha_read_idx == 15) state <= ST_LOAD_REG_S;
                    else begin
                        sha_read_idx <= sha_read_idx + 1;
                        state        <= ST_READ_HASH_REQ;
                    end
                end

                // --- 5. Push Valid Data into Ed25519 Registers ---
                ST_LOAD_REG_S: begin
                    ed_ext_we       <= 1'b1;
                    ed_ext_dest_sel <= 5'd23;    // Reg 23 = S
                    ed_data_sel     <= 2'b01;    // Route from ext_data_1
                    ed_ext_data_1   <= s_reg;
                    state           <= ST_LOAD_REG_R;
                end
                ST_LOAD_REG_R: begin
                    ed_ext_dest_sel <= 5'd20;    // Reg 20 = R
                    ed_ext_data_1   <= r_reg;
                    state           <= ST_LOAD_REG_A;
                end
                ST_LOAD_REG_A: begin
                    ed_ext_dest_sel <= 5'd21;    // Reg 21 = PubKey
                    ed_ext_data_1   <= pubkey_reg;
                    state           <= ST_LOAD_REG_HLO;
                end
                ST_LOAD_REG_HLO: begin
                    ed_ext_dest_sel <= 5'd8;     // Reg 8 = Hash Low
                    ed_ext_data_1   <= hash_reg[255:0];
                    state           <= ST_LOAD_REG_HHI;
                end
                ST_LOAD_REG_HHI: begin
                    ed_ext_dest_sel <= 5'd9;     // Reg 9 = Hash High
                    ed_ext_data_1   <= hash_reg[511:256];
                    state           <= ST_ED_START;
                end

                // --- 6. Kick Off Verification ---
                ST_ED_START: begin
                    ed_ext_we <= 1'b0;  // Release override
                    ed_start  <= 1'b1;
                    state     <= ST_ED_WAIT;
                end

                ST_ED_WAIT: begin
                    ed_start <= 1'b0;
                    if (ed_done) begin
                        demo_done       <= 1'b1;
                        signature_valid <= ed_valid;
                        state           <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    if (!start_demo) state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule