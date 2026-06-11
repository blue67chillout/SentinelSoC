module sha512_preprocessor( 
    input  logic        clk, 
    input  logic        rst_n,
    input  logic        start_i,
    input  logic [31:0] msg_words_i,
    input  logic        word_ack_i,
    output logic        done_o,
    output logic        mux_sel_o,
    output logic [31:0] fsm_data_o
);
    typedef enum logic [2:0] {
        IDLE     = 3'b000,
        SEND80   = 3'b010,
        SEND00   = 3'b011,
        SENDLEN0 = 3'b100,
        SENDLEN1 = 3'b101
    } state_t;

    state_t      state, next_state;
    logic [31:0] N_cnt;
    logic [5:0]  C_cnt;
    logic [4:0]  K;
    logic [5:0]  C;

    // K: slot where 0x80 goes = N (next slot after last message slot)
    assign K = msg_words_i[4:0];   

    // C: zero words between 0x80 and SENDLEN0
    // We need 4 words for the 128-bit length (indices 28, 29, 30, 31).
    // If 0x80 cannot fit before index 28 (i.e. K >= 28), we must overflow.
    // Total zeros for overflow = remaining space in current block + 30 zeros in next block.
    assign C = (K >= 5'd28) ? (6'd61 - {1'b0, K}) : (6'd29 - {1'b0, K});

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            N_cnt <= 32'd0;
            C_cnt <= 6'd0;
        end else begin
            state <= next_state;
            if (start_i) begin
                N_cnt <= 32'd0;
                C_cnt <= 6'd0;
            end else if (word_ack_i) begin
                if (state == IDLE)   N_cnt <= N_cnt + 1;
                if (state == SEND00) C_cnt <= C_cnt + 1;
            end
        end
    end

    always_comb begin
        next_state = state;
        done_o     = 1'b0;
        case (state)
            IDLE: begin
                if (start_i && msg_words_i == 0)
                    next_state = SEND80;
                else if (word_ack_i && (N_cnt == msg_words_i - 1))
                    next_state = SEND80;
            end
            SEND80: begin
                if (word_ack_i) next_state = (C == 0) ? SENDLEN0 : SEND00;
            end
            SEND00: begin
                if (word_ack_i && (C_cnt == C - 1)) next_state = SENDLEN0;
            end
            SENDLEN0: begin
                if (word_ack_i) next_state = SENDLEN1;
            end
            SENDLEN1: begin
                if (word_ack_i) begin
                    next_state = IDLE;
                    done_o     = 1'b1;
                end
            end
            default: next_state = IDLE;
        endcase 
    end

    assign mux_sel_o = (state != IDLE);
 
    logic [31:0] len_bits;
    assign len_bits = msg_words_i << 5;
    logic [31:0] len_val;
    assign len_val = {len_bits[7:0], len_bits[15:8], len_bits[23:16], len_bits[31:24]};
    
    always_comb begin
        fsm_data_o = 32'h0;
        case (state) 
            SEND80:   fsm_data_o = 32'h00000080;
            SEND00:   fsm_data_o = 32'h00000000;
            SENDLEN1: fsm_data_o = len_val;       // bit length, low word
            SENDLEN0: fsm_data_o = 32'h00000000;  // upper word of 128-bit length = 0
            default:  fsm_data_o = 32'h00000000;
        endcase
    end

endmodule
