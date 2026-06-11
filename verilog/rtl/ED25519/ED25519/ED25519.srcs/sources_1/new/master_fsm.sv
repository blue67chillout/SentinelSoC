module master_fsm (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start_verify,
    
    // Status to Top-Level
    output logic         verify_done,
    output logic         signature_valid,

    // Micro-Sequencer Interface
    output logic         start_seq,
    output logic [4:0]   seq_id,          
    input  logic         seq_done,    
    
    // Datapath Data Interface
    input  logic [255:0] datapath_read_data, // Wired to RegFile A_out
    input  logic         cmp_eq              // Wired to ALU cmp_eq
);

    // --- Ed25519 Hardware Exponents ---
    localparam logic [254:0] EXP_P_MINUS_2       = 255'h7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEB;
    localparam logic [251:0] EXP_P_PLUS_3_OVER_8 = 252'h0FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE;

    // --- State Encoding ---
    typedef enum logic [5:0] { 
        ST_IDLE,
        
        // --- Step 1 & 2: Hash & s*G ---
        ST_HASH_REDUCTION,
        ST_LOAD_S,       
        ST_INIT_P1,      
        ST_S2_DOUBLE,
        ST_S2_CHECK_BIT,
        ST_S2_ADD,
        ST_S2_SHIFT,
        ST_S2_SAVE_P1,   
        
        // --- Step 3: Decompression (Runs twice for A and R) ---
        ST_DECOMP_START,
        ST_S3_UV,   
        ST_S3_INV_SETUP,     
        ST_S3_XSQ,      
        ST_S3_SQRT_SETUP,    
        ST_S3_FUDGE_CHECK,   
        ST_S3_FUDGE_MULT,    
        ST_S3_FIX_SIGN,      
        ST_S3_PACK,    
        ST_S3_SAVE_A,
        ST_S3_SAVE_R,        
        
        // --- Shared Exponentiation Subroutine ---
        ST_EXP_SQUARE,
        ST_EXP_CHECK_BIT,
        ST_EXP_MULT,
        ST_EXP_SHIFT,
        
        // --- Step 4 & 5: h*A + R and Verify ---
        ST_S4_LOAD_H,
        ST_S4_INIT_P2,
        ST_S4_DOUBLE,
        ST_S4_CHECK_BIT,
        ST_S4_ADD_A,
        ST_S4_SHIFT,
        ST_S4_LOAD_R_BASE,   
        ST_S4_ADD_R,
        ST_S5_VERIFY_X,
        ST_S5_VERIFY_Y,
        
        ST_DONE
    } state_t;

    state_t state, next_state, return_state;

    // --- Internal Shadow Registers ---
    logic [255:0] scalar_reg;
    logic [7:0]   bit_counter;
    logic         current_msb;     
    logic         target_exponent; // 0 for P-2, 1 for (P+3)/8
    logic         current_exp_bit; 
    logic         is_decomp_pubkey;
    
    // Latch registers for final hardware evaluation
    logic         cmp_eq_latch;    
    logic         x_eq_flag;
    logic         y_eq_flag;
    
    assign current_msb = scalar_reg[255]; 

    // --- Purely Combinational Exponent Bit Selection ---
    always_comb begin
        if (target_exponent == 1'b0)
            current_exp_bit = EXP_P_MINUS_2[bit_counter];
        else
            current_exp_bit = EXP_P_PLUS_3_OVER_8[bit_counter];
    end

    // --- Sequential Logic ---
    logic start_seq_reg;
    assign start_seq = start_seq_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            return_state     <= ST_IDLE;
            start_seq_reg    <= 1'b0;
            bit_counter      <= 8'd0;
            scalar_reg       <= 256'd0;
            target_exponent  <= 1'b0;
            is_decomp_pubkey <= 1'b1;
            cmp_eq_latch     <= 1'b0;
            x_eq_flag        <= 1'b0;
            y_eq_flag        <= 1'b0;
        end else begin
            state <= next_state;

            // CLEAN LATCH: Safely grabs the ALU comparator result when sequence finishes
            //if (seq_done) cmp_eq_latch <= cmp_eq;
            
            // Latch Final Verification Flags
            if (state == ST_S5_VERIFY_X && seq_done) x_eq_flag <= cmp_eq;
            if (state == ST_S5_VERIFY_Y && seq_done) y_eq_flag <= cmp_eq;

            // --- FSM Hardware Trigger Pulse ---
            if ((next_state != state) && (
                next_state == ST_HASH_REDUCTION || next_state == ST_LOAD_S         ||
                next_state == ST_INIT_P1        || next_state == ST_S2_DOUBLE      ||
                next_state == ST_S2_ADD         || next_state == ST_S2_SAVE_P1     ||
                next_state == ST_DECOMP_START   || next_state == ST_S3_UV          || 
                next_state == ST_S3_INV_SETUP   || next_state == ST_S3_XSQ         || 
                next_state == ST_S3_SQRT_SETUP  || next_state == ST_S3_FUDGE_CHECK ||
                next_state == ST_S3_FUDGE_MULT  || next_state == ST_S3_FIX_SIGN    ||
                next_state == ST_S3_PACK        || next_state == ST_S3_SAVE_A      ||
                next_state == ST_S3_SAVE_R      || next_state == ST_EXP_SQUARE     ||
                next_state == ST_EXP_MULT       || next_state == ST_S4_LOAD_H      || 
                next_state == ST_S4_INIT_P2     || next_state == ST_S4_DOUBLE      || 
                next_state == ST_S4_ADD_A       || next_state == ST_S4_LOAD_R_BASE || 
                next_state == ST_S4_ADD_R       || next_state == ST_S5_VERIFY_X    ||
                next_state == ST_S5_VERIFY_Y
            )) begin
                start_seq_reg <= 1'b1;
            end else begin
                start_seq_reg <= 1'b0;
            end
            
            // --- Shift Registers & Setup Subroutines ---
            if ((state == ST_LOAD_S || state == ST_S4_LOAD_H) && seq_done) begin
                scalar_reg  <= datapath_read_data;
                bit_counter <= 8'd255; 
            end
            else if (state == ST_S2_SHIFT || state == ST_S4_SHIFT) begin
                scalar_reg  <= scalar_reg << 1;
                bit_counter <= bit_counter - 1;
            end
            else if (state == ST_S2_SAVE_P1 && seq_done) begin
                is_decomp_pubkey <= 1'b1; // Setup first decomp pass for A
            end
            else if (state == ST_S3_SAVE_A && seq_done) begin
                is_decomp_pubkey <= 1'b0; // Setup second decomp pass for R
            end
            else if (state == ST_S3_INV_SETUP && seq_done) begin
                target_exponent <= 1'b0;      // P-2
                bit_counter     <= 8'd254;    // 255 bits long
                return_state    <= ST_S3_XSQ;
            end
            else if (state == ST_S3_SQRT_SETUP && seq_done) begin
                target_exponent <= 1'b1;      // (P+3)/8
                bit_counter     <= 8'd251;    // 252 bits long
                return_state    <= ST_S3_FUDGE_CHECK;
            end
            else if (state == ST_EXP_SHIFT) begin
                bit_counter <= bit_counter - 1;
            end
        end
    end

    // --- Combinational Logic (Next State & ROM Addressing) ---
    always_comb begin
        next_state  = state;        
        seq_id      = 5'd0;
        verify_done = 1'b0;
        signature_valid = 1'b0;

        case (state)
            ST_IDLE: begin
                if (start_verify) next_state = ST_HASH_REDUCTION;
            end
            
            // ==========================================
            // PHASE 1 & 2: Hash & P1 = s * G
            // ==========================================
            ST_HASH_REDUCTION: begin seq_id = 5'd0; if (seq_done) next_state = ST_LOAD_S; end
            ST_LOAD_S:         begin seq_id = 5'd4; if (seq_done) next_state = ST_INIT_P1; end
            ST_INIT_P1:        begin seq_id = 5'd3; if (seq_done) next_state = ST_S2_DOUBLE; end
            ST_S2_DOUBLE:      begin seq_id = 5'd1; if (seq_done) next_state = ST_S2_CHECK_BIT; end
            
            ST_S2_CHECK_BIT: begin
                if (current_msb) next_state = ST_S2_ADD;
                else             next_state = ST_S2_SHIFT;
            end
            
            ST_S2_ADD:   begin seq_id = 5'd2; if (seq_done) next_state = ST_S2_SHIFT; end
            ST_S2_SHIFT: begin
                if (bit_counter == 8'd0) next_state = ST_S2_SAVE_P1;
                else                     next_state = ST_S2_DOUBLE;
            end
            ST_S2_SAVE_P1: begin seq_id = 5'd5; if (seq_done) next_state = ST_DECOMP_START; end

            // ==========================================
            // PHASE 3: Decompression (A then R)
            // ==========================================
            ST_DECOMP_START: begin 
                seq_id = is_decomp_pubkey ? 5'd11 : 5'd12; // Load A or R
                if (seq_done) next_state = ST_S3_UV; 
            end
            
            ST_S3_UV:         begin seq_id = 5'd6;  if (seq_done) next_state = ST_S3_INV_SETUP; end
            ST_S3_INV_SETUP:  begin seq_id = 5'd7;  if (seq_done) next_state = ST_EXP_SQUARE; end
            ST_S3_XSQ:        begin seq_id = 5'd10; if (seq_done) next_state = ST_S3_SQRT_SETUP; end
            ST_S3_SQRT_SETUP: begin seq_id = 5'd13; if (seq_done) next_state = ST_EXP_SQUARE; end
            
            ST_S3_FUDGE_CHECK: begin
                seq_id = 5'd14; 
                if (seq_done) begin
                    if (cmp_eq) next_state = ST_S3_FIX_SIGN;
                    if (cmp_eq) next_state = ST_S3_FIX_SIGN;
                    else              next_state = ST_S3_FUDGE_MULT;
                end
            end
            
            ST_S3_FUDGE_MULT: begin seq_id = 5'd15; if (seq_done) next_state = ST_S3_FIX_SIGN; end
            ST_S3_FIX_SIGN:   begin seq_id = 5'd16; if (seq_done) next_state = ST_S3_PACK; end
            ST_S3_PACK: begin
                seq_id = 5'd17;    
                if (seq_done) begin
                    if (is_decomp_pubkey) next_state = ST_S3_SAVE_A;
                    else                  next_state = ST_S3_SAVE_R; 
                end
            end
            ST_S3_SAVE_A: begin seq_id = 5'd19; if (seq_done) next_state = ST_DECOMP_START; end
            ST_S3_SAVE_R: begin seq_id = 5'd18; if (seq_done) next_state = ST_S4_LOAD_H; end

            // ==========================================
            // SHARED EXPONENTIATION SUBROUTINE
            // ==========================================
            ST_EXP_SQUARE: begin seq_id = 5'd8; if (seq_done) next_state = ST_EXP_CHECK_BIT; end
            ST_EXP_CHECK_BIT: begin
                if (current_exp_bit) next_state = ST_EXP_MULT;
                else                 next_state = ST_EXP_SHIFT;
            end
            ST_EXP_MULT:  begin seq_id = 5'd9; if (seq_done) next_state = ST_EXP_SHIFT; end // Note: ROM 10 is EXP_MULT
            ST_EXP_SHIFT: begin
                if (bit_counter == 8'd0) next_state = return_state; 
                else                     next_state = ST_EXP_SQUARE;
            end

            // ==========================================
            // PHASE 4: h * A + R
            // ==========================================
            ST_S4_LOAD_H:  begin seq_id = 5'd23; if (seq_done) next_state = ST_S4_INIT_P2; end
            ST_S4_INIT_P2: begin seq_id = 5'd3;  if (seq_done) next_state = ST_S4_DOUBLE; end
            ST_S4_DOUBLE:  begin seq_id = 5'd1;  if (seq_done) next_state = ST_S4_CHECK_BIT; end

            ST_S4_CHECK_BIT: begin
                if (current_msb) next_state = ST_S4_ADD_A;
                else             next_state = ST_S4_SHIFT;
            end

            ST_S4_ADD_A:   begin seq_id = 5'd2; if (seq_done) next_state = ST_S4_SHIFT; end
            ST_S4_SHIFT: begin
                if (bit_counter == 8'd0) next_state = ST_S4_LOAD_R_BASE;
                else                     next_state = ST_S4_DOUBLE;
            end

            ST_S4_LOAD_R_BASE: begin seq_id = 5'd20; if (seq_done) next_state = ST_S4_ADD_R; end
            ST_S4_ADD_R:       begin seq_id = 5'd2;  if (seq_done) next_state = ST_S5_VERIFY_X; end

            // ==========================================
            // PHASE 5: Authentication Check (P1 == P2)
            // ==========================================
            ST_S5_VERIFY_X: begin seq_id = 5'd21; if (seq_done) next_state = ST_S5_VERIFY_Y; end
            ST_S5_VERIFY_Y: begin seq_id = 5'd22; if (seq_done) next_state = ST_DONE; end

            ST_DONE: begin
                verify_done = 1'b1;
                signature_valid = x_eq_flag & y_eq_flag; // Verdict!
            end
            
            default: next_state = ST_IDLE;
        endcase
    end
endmodule