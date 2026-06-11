import sha512_pkg::*;

module sha512_top (
    input  logic        clk,
    input  logic        rst_n,

    // Memory-mapped interface
    input  logic [5:0]  addr_i,  
    input  logic        wr_en_i,  
    input  logic [31:0] wdata_i, 
    
    output logic [31:0] rdata_o, 
    output logic        intr_o   
);
    // --------------------------------------------------------
    // FSM States
    // --------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE  = 3'd0, // Waiting for start command
        S_RECV  = 3'd1, // Receiving raw words from CPU
        S_PAD   = 3'd2, // Auto-padding via preprocessor
        S_WORK  = 3'd3, // Executing 80 hashing rounds
        S_ACCUM = 3'd4, // Accumulating block hash
        S_DONE  = 3'd5  // Hashing fully complete
    } top_state_t;
    
    top_state_t state;
    logic [6:0] round_count;
    logic [5:0] word_count; // Tracks words in current 1024-bit block (0 to 32)
    logic       is_last_block;

    // --------------------------------------------------------
    // Hash State & Registers
    // --------------------------------------------------------
    logic [31:0] msg_length;
    word_t a, b, c, d, e, f, g, h;
    word_t H [8]; 

    word_t a_n, b_n, c_n, d_n, e_n, f_n, g_n, h_n; 
    word_t sched_w_out; 
    word_t w_i, k_i; 

    // --------------------------------------------------------
    // Preprocessor Instantiation & Routing
    // --------------------------------------------------------
    logic prep_start;
    logic prep_word_ack;
    logic prep_done;
    logic prep_mux_sel;
    logic [31:0] prep_data;

    // Trigger preprocessor on write to control register (0x20) with bit 0 high
    assign prep_start = (wr_en_i && addr_i == 6'h20 && wdata_i[0]);

    sha512_preprocessor u_prep (
        .clk         (clk),
        .rst_n       (rst_n),
        .start_i     (prep_start),
        .msg_words_i (msg_length),
        .word_ack_i  (prep_word_ack),
        .done_o      (prep_done),
        .mux_sel_o   (prep_mux_sel),
        .fsm_data_o  (prep_data)
    );

    // --------------------------------------------------------
    // Message Scheduler Routing
    // --------------------------------------------------------
    logic [4:0]  sched_addr;
    logic        sched_wr;
    logic        sched_wr_low;
    logic        sched_wr_high;
    logic [31:0] sched_wdata;

    // Multiplex CPU writes vs Preprocessor writes
    assign sched_addr  = (state == S_PAD) ? word_count[4:0] : addr_i[4:0];
    assign sched_wr    = (state == S_PAD) ? 1'b1 : (wr_en_i && addr_i < 32 && state == S_RECV);
    assign sched_wdata = (state == S_PAD) ? prep_data : wdata_i;

    assign sched_wr_low  = sched_wr && sched_addr[0];
    assign sched_wr_high = sched_wr && !sched_addr[0];

    // Ack preprocessor either when CPU writes in RECV, or automatically in PAD
    assign prep_word_ack = (state == S_RECV) ? sched_wr : 
                           (state == S_PAD)  ? 1'b1 : 1'b0;

    sha512_msg_sched u_sched (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_idx_i   (sched_addr[4:1]),
        .wr_low_i   (sched_wr_low),
        .wr_high_i  (sched_wr_high),
        .wr_data_i  (sched_wdata),
        .en         (state == S_WORK),
        .w_out      (sched_w_out)
    );

    // --------------------------------------------------------
    // Round Core Instantiation
    // --------------------------------------------------------
    always_ff @(posedge clk) begin
        w_i <= sched_w_out;          
        k_i <= K[round_count];       
    end

    sha512_round u_round (.*); 

    // --------------------------------------------------------
    // Main Top Control FSM
    // --------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            word_count    <= 6'd0;
            is_last_block <= 1'b0;
            round_count   <= 7'd0;
            intr_o        <= 1'b0;
            msg_length    <= 32'd0;
            {a,b,c,d,e,f,g,h} <= '0;
            for (int i=0; i<8; i++) H[i] <= SHA512_IV[i];
        end else begin
            // Capture message length
            if (wr_en_i && addr_i == 6'h32) msg_length <= wdata_i;

            case (state)
                S_IDLE: begin
                    intr_o        <= 1'b0;
                    word_count    <= 6'd0;
                    is_last_block <= 1'b0;

                    if (prep_start) begin
                        state <= S_RECV;
                        if (wdata_i[1]) begin // init_cmd (First Block)
                            {a,b,c,d,e,f,g,h} <= {SHA512_IV[0], SHA512_IV[1], SHA512_IV[2], SHA512_IV[3],
                                                  SHA512_IV[4], SHA512_IV[5], SHA512_IV[6], SHA512_IV[7]}; 
                            for (int i=0; i<8; i++) H[i] <= SHA512_IV[i];
                        end else begin // Subsequent Blocks
                            {a,b,c,d,e,f,g,h} <= {H[0], H[1], H[2], H[3], H[4], H[5], H[6], H[7]}; 
                        end
                    end
                end

                S_RECV: begin
                    if (sched_wr) word_count <= word_count + 1;

                    // If the 32-word block is filled by CPU writes, hash it
                    if (word_count == 32 || (sched_wr && word_count == 31)) begin
                        state <= S_WORK;
                        round_count <= 0;
                    end 
                    // CPU finished streaming, hardware FSM takes over to pad
                    else if (prep_mux_sel) begin
                        state <= S_PAD; 
                    end
                end

                S_PAD: begin
                    word_count <= word_count + 1;
                    
                    if (prep_done) is_last_block <= 1'b1;

                    // Once padded to exactly 32 words, process the block
                    if (word_count == 31) begin
                        state <= S_WORK;
                        round_count <= 0;
                    end
                end

                S_WORK: begin
                    round_count <= round_count + 1; // always increment
                    if (round_count >= 1) begin
                        {a,b,c,d,e,f,g,h} <= {a_n,b_n,c_n,d_n,e_n,f_n,g_n,h_n};
                    end
                    if (round_count == 80) begin
                        state <= S_ACCUM;
                    end
                end 

                S_ACCUM: begin
                    H[0] <= H[0] + a; H[1] <= H[1] + b;
                    H[2] <= H[2] + c; H[3] <= H[3] + d;
                    H[4] <= H[4] + e; H[5] <= H[5] + f;
                    H[6] <= H[6] + g; H[7] <= H[7] + h;
                    
                    word_count <= 6'd0; // Reset index for next block (if any)
                    
                    if (is_last_block) begin
                        state <= S_DONE;
                    end else begin
                        // Load updated H back into a-h for the next block
                        {a,b,c,d,e,f,g,h} <= {H[0]+a, H[1]+b, H[2]+c, H[3]+d, H[4]+e, H[5]+f, H[6]+g, H[7]+h};
                        
                        // Decide if we resume padding or wait for more CPU data
                        if (prep_mux_sel) state <= S_PAD;
                        else state <= S_RECV;
                    end
                end

                S_DONE: begin
                    intr_o <= 1'b1;
                    state  <= S_IDLE;
                end
            endcase
        end
    end

    // --------------------------------------------------------
    // Output Read Logic
    // --------------------------------------------------------
    logic ready;
    // CHANGE: Allow testbench to know we are ready to receive the next block
    assign ready = (state == S_IDLE) || (state == S_RECV);

    always_comb begin
            rdata_o = 32'h0;
            if (addr_i == 6'h21) 
                rdata_o = {31'h0, ready}; 
            else if (addr_i >= 6'h22 && addr_i <= 6'h31) begin
                automatic logic [31:0] raw;
                raw = addr_i[0] ? H[(addr_i-6'h22)>>1][31:0] : H[(addr_i-6'h22)>>1][63:32];
                rdata_o = raw; // <--- CHANGED: Removed the `{raw[7:0], ...}` byte swap
            end
    end
endmodule
