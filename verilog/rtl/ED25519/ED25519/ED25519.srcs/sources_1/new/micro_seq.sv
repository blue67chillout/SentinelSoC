module micro_sequencer (
    input  logic        clk, rst_n, start_seq, mult_done, cmp_flag,
    input  logic [4:0]  seq_id, 

    output logic [4:0]  a_sel, b_sel, dest_sel,
    output logic        reg_we, seq_done, 
    output logic [2:0]  alu_op,
    output logic        sel_hi,
    output logic        mult_kick,
    output logic        mod_p_en
);
    // --- ALU Opcodes ---
    localparam OP_ADD             = 3'b000;
    localparam OP_SUB_CND         = 3'b001;
    localparam OP_MULT            = 3'b010;
    localparam OP_CMP             = 3'b011;
    localparam OP_PASS            = 3'b100;
    localparam OP_SUB_RAW         = 3'b101;
    localparam OP_LOAD_COMPRESSED = 3'b110; 
    localparam OP_COND_NEGATE     = 3'b111; 

    typedef enum logic [2:0] { S_IDLE, S_START, S_WAIT_DROP, S_EXE, S_WRITE } sub_step_t;
    sub_step_t sub_step;
    logic [5:0] step_counter; 
    logic [2:0] rom_alu_op;
    
    // --- Internal Wires & Registers ---
    logic rom_is_last_step;    
    logic seq_done_reg;    
    

    assign seq_done   = seq_done_reg;
    

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            step_counter   <= 0;
            sub_step       <= S_IDLE;
            reg_we         <= 1'b0;
            seq_done_reg   <= 1'b0;
            
        end else begin
            reg_we <= 1'b0; 
            case (sub_step)
                S_IDLE: begin
                    seq_done_reg   <= 1'b0;
                    
                    if (start_seq) begin
                        step_counter <= 0;
                        sub_step     <= S_START;
                    end
                end
                S_START: begin
                    if (rom_alu_op == OP_MULT) sub_step <= S_WAIT_DROP; 
                    else                       sub_step <= S_EXE;       
                end
                S_WAIT_DROP: begin
                    sub_step <= S_EXE; 
                end
                S_EXE: begin
                    if (rom_alu_op != OP_MULT || mult_done) begin
                        sub_step <= S_WRITE;
                        reg_we   <= 1'b1;
                    end
                end
                S_WRITE: begin
                    if (rom_is_last_step) begin
                        seq_done_reg   <= 1'b1;                         
                        sub_step       <= S_IDLE;
                    end else begin
                        step_counter <= step_counter + 6'd1;
                        sub_step     <= S_START;
                    end
                end
                default: sub_step <= S_IDLE;
            endcase
        end
    end
    
    
    always_comb begin
        a_sel = '0; b_sel = '0; dest_sel = '0; sel_hi = '0;
        rom_alu_op = OP_PASS; 
        rom_is_last_step = 1'b0;        
        mod_p_en         = 1'b0;        

        case (seq_id)
            5'd0: begin // BARRETT REDUCTION
                case (step_counter)
                    6'd0:  begin a_sel=5'd9;  b_sel=5'd10; rom_alu_op=OP_MULT;    sel_hi=1'b0; dest_sel=5'd15; end
                    6'd1:  begin a_sel=5'd9;  b_sel=5'd12; rom_alu_op=OP_MULT;    sel_hi=1'b1; dest_sel=5'd13; end
                    6'd2:  begin a_sel=5'd15; b_sel=5'd13; rom_alu_op=OP_ADD;     sel_hi=1'b0; dest_sel=5'd15; end
                    6'd3:  begin a_sel=5'd8;  b_sel=5'd10; rom_alu_op=OP_MULT;    sel_hi=1'b1; dest_sel=5'd13; end
                    6'd4:  begin a_sel=5'd15; b_sel=5'd13; rom_alu_op=OP_ADD;     sel_hi=1'b0; dest_sel=5'd9;  end
                    6'd5:  begin a_sel=5'd9;  b_sel=5'd11; rom_alu_op=OP_MULT;    sel_hi=1'b0; dest_sel=5'd15; end
                    6'd6:  begin a_sel=5'd8;  b_sel=5'd15; rom_alu_op=OP_SUB_RAW; sel_hi=1'b0; dest_sel=5'd15; end
                    6'd7:  begin a_sel=5'd15; b_sel=5'd11; rom_alu_op=OP_SUB_CND; sel_hi=1'b0; dest_sel=5'd15; end
                    6'd8:  begin a_sel=5'd15; b_sel=5'd11; rom_alu_op=OP_SUB_CND; sel_hi=1'b0; dest_sel=5'd15; end
                    6'd9:  begin a_sel=5'd15; b_sel=5'd11; rom_alu_op=OP_SUB_CND; sel_hi=1'b0; dest_sel=5'd16; rom_is_last_step=1'b1; end
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd1: begin // POINT DOUBLING
                mod_p_en = 1'b1; 
                case (step_counter)
                    6'd0:  begin a_sel=5'd0;  b_sel=5'd0;  rom_alu_op=OP_MULT;    dest_sel=5'd8;  end 
                    6'd1:  begin a_sel=5'd1;  b_sel=5'd1;  rom_alu_op=OP_MULT;    dest_sel=5'd9;  end 
                    6'd2:  begin a_sel=5'd2;  b_sel=5'd2;  rom_alu_op=OP_MULT;    dest_sel=5'd10; end 
                    6'd3:  begin a_sel=5'd10; b_sel=5'd10; rom_alu_op=OP_ADD;     dest_sel=5'd10; end 
                    6'd4:  begin a_sel=5'd0;  b_sel=5'd1;  rom_alu_op=OP_ADD;     dest_sel=5'd11; end 
                    6'd5:  begin a_sel=5'd11; b_sel=5'd11; rom_alu_op=OP_MULT;    dest_sel=5'd11; end 
                    6'd6:  begin a_sel=5'd8;  b_sel=5'd9;  rom_alu_op=OP_ADD;     dest_sel=5'd12; end 
                    6'd7:  begin a_sel=5'd11; b_sel=5'd12; rom_alu_op=OP_SUB_RAW; dest_sel=5'd11; end 
                    6'd8:  begin a_sel=5'd9;  b_sel=5'd8;  rom_alu_op=OP_SUB_RAW; dest_sel=5'd13; end 
                    6'd9:  begin a_sel=5'd10; b_sel=5'd13; rom_alu_op=OP_SUB_RAW; dest_sel=5'd14; end 
                    6'd10: begin a_sel=5'd11; b_sel=5'd14; rom_alu_op=OP_MULT;    dest_sel=5'd0;  end 
                    6'd11: begin a_sel=5'd13; b_sel=5'd12; rom_alu_op=OP_MULT;    dest_sel=5'd1;  end 
                    6'd12: begin a_sel=5'd11; b_sel=5'd12; rom_alu_op=OP_MULT;    dest_sel=5'd3;  end 
                    6'd13: begin a_sel=5'd14; b_sel=5'd13; rom_alu_op=OP_MULT;    dest_sel=5'd2;  rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd2: begin // POINT ADDITION
                mod_p_en = 1'b1; 
                case (step_counter)
                    6'd0:  begin a_sel=5'd1;  b_sel=5'd0;  rom_alu_op=OP_SUB_RAW; dest_sel=5'd8;  end 
                    6'd1:  begin a_sel=5'd5;  b_sel=5'd4;  rom_alu_op=OP_SUB_RAW; dest_sel=5'd9;  end 
                    6'd2:  begin a_sel=5'd8;  b_sel=5'd9;  rom_alu_op=OP_MULT;    dest_sel=5'd8;  end 
                    6'd3:  begin a_sel=5'd1;  b_sel=5'd0;  rom_alu_op=OP_ADD;     dest_sel=5'd9;  end 
                    6'd4:  begin a_sel=5'd5;  b_sel=5'd4;  rom_alu_op=OP_ADD;     dest_sel=5'd10; end 
                    6'd5:  begin a_sel=5'd9;  b_sel=5'd10; rom_alu_op=OP_MULT;    dest_sel=5'd9;  end 
                    6'd6:  begin a_sel=5'd27; b_sel=5'd7;  rom_alu_op=OP_MULT;    dest_sel=5'd10; end 
                    6'd7:  begin a_sel=5'd3;  b_sel=5'd10; rom_alu_op=OP_MULT;    dest_sel=5'd10; end 
                    6'd8:  begin a_sel=5'd6;  b_sel=5'd6;  rom_alu_op=OP_ADD;     dest_sel=5'd11; end 
                    6'd9:  begin a_sel=5'd2;  b_sel=5'd11; rom_alu_op=OP_MULT;    dest_sel=5'd11; end 
                    6'd10: begin a_sel=5'd9;  b_sel=5'd8;  rom_alu_op=OP_SUB_RAW; dest_sel=5'd12; end 
                    6'd11: begin a_sel=5'd9;  b_sel=5'd8;  rom_alu_op=OP_ADD;     dest_sel=5'd8;  end 
                    6'd12: begin a_sel=5'd11; b_sel=5'd10; rom_alu_op=OP_SUB_RAW; dest_sel=5'd13; end 
                    6'd13: begin a_sel=5'd11; b_sel=5'd10; rom_alu_op=OP_ADD;     dest_sel=5'd14; end 
                    6'd14: begin a_sel=5'd12; b_sel=5'd13; rom_alu_op=OP_MULT;    dest_sel=5'd0;  end 
                    6'd15: begin a_sel=5'd14; b_sel=5'd8;  rom_alu_op=OP_MULT;    dest_sel=5'd1;  end 
                    6'd16: begin a_sel=5'd12; b_sel=5'd8;  rom_alu_op=OP_MULT;    dest_sel=5'd3;  end 
                    6'd17: begin a_sel=5'd13; b_sel=5'd14; rom_alu_op=OP_MULT;    dest_sel=5'd2;  rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd3: begin // INIT NEUTRAL POINT
                case (step_counter)
                    6'd0: begin a_sel=5'd24; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd0; end 
                    6'd1: begin a_sel=5'd25; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd1; end 
                    6'd2: begin a_sel=5'd25; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd2; end 
                    6'd3: begin a_sel=5'd24; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd3; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd4: begin // EXPORT SCALAR S
                case (step_counter)
                    6'd0: begin a_sel=5'd23; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd23; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd5: begin // SAVE P1
                case (step_counter)
                    6'd0: begin a_sel=5'd0; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd17; end
                    6'd1: begin a_sel=5'd1; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd18; end
                    6'd2: begin a_sel=5'd2; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd19; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd6: begin // CALC UV
                mod_p_en = 1'b1;
                case (step_counter)
                    6'd0: begin a_sel=5'd8;  b_sel=5'd8;  rom_alu_op=OP_MULT;    dest_sel=5'd9;  end 
                    6'd1: begin a_sel=5'd9;  b_sel=5'd25; rom_alu_op=OP_SUB_RAW; dest_sel=5'd15; end 
                    6'd2: begin a_sel=5'd26; b_sel=5'd9;  rom_alu_op=OP_MULT;    dest_sel=5'd9;  end 
                    6'd3: begin a_sel=5'd9;  b_sel=5'd25; rom_alu_op=OP_ADD;     dest_sel=5'd10; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd7: begin // INIT EXP ENGINE
                case (step_counter)
                    6'd0: begin a_sel=5'd10; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd12; end 
                    6'd1: begin a_sel=5'd25; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd11; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd8: begin // EXP SQUARE
                mod_p_en = 1'b1;
                case (step_counter)
                    6'd0: begin a_sel=5'd11; b_sel=5'd11; rom_alu_op=OP_MULT; dest_sel=5'd11; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd9: begin // EXP MULT BASE
                mod_p_en = 1'b1;
                case (step_counter)
                    6'd0: begin a_sel=5'd11; b_sel=5'd12; rom_alu_op=OP_MULT; dest_sel=5'd11; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd10: begin // CALC XSQ
                mod_p_en = 1'b1;
                case (step_counter)
                    6'd0: begin a_sel=5'd15; b_sel=5'd11; rom_alu_op=OP_MULT; dest_sel=5'd13; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd11: begin // LOAD PUBKEY TO PORT
                case (step_counter)
                    6'd0: begin a_sel=5'd21; b_sel=5'd0; rom_alu_op=OP_LOAD_COMPRESSED; dest_sel=5'd8; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd12: begin // LOAD R TO PORT
                case (step_counter)
                    6'd0: begin a_sel=5'd20; b_sel=5'd0; rom_alu_op=OP_LOAD_COMPRESSED; dest_sel=5'd8; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd13: begin // INIT EXP ENGINE FOR XSQ
                case (step_counter)
                    6'd0: begin a_sel=5'd13; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd12; end 
                    6'd1: begin a_sel=5'd25; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd11; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd14: begin // FUDGE CHECK
                mod_p_en = 1'b1; // First is mult, second is cmp. Cmp ignores mod_p_en naturally.
                case (step_counter)
                    6'd0: begin a_sel=5'd11; b_sel=5'd11; rom_alu_op=OP_MULT; dest_sel=5'd14; end 
                    6'd1: begin a_sel=5'd14; b_sel=5'd13; rom_alu_op=OP_CMP;  dest_sel=5'd14; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd15: begin // MULT SQRTM1
                mod_p_en = 1'b1;
                case (step_counter)
                    6'd0: begin a_sel=5'd11; b_sel=5'd28; rom_alu_op=OP_MULT; dest_sel=5'd11; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd16: begin // FIX X SIGN
                case (step_counter)
                    6'd0: begin a_sel=5'd11; b_sel=5'd0; rom_alu_op=OP_COND_NEGATE; dest_sel=5'd11; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd17: begin // PACK POINT
                mod_p_en = 1'b1;
                case (step_counter)
                    6'd0: begin a_sel=5'd11; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd0; end 
                    6'd1: begin a_sel=5'd8;  b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd1; end 
                    6'd2: begin a_sel=5'd25; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd2; end 
                    6'd3: begin a_sel=5'd11; b_sel=5'd8; rom_alu_op=OP_MULT; dest_sel=5'd3; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd18: begin // SAVE R
                case (step_counter)
                    6'd0: begin a_sel=5'd0; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd20; end 
                    6'd1: begin a_sel=5'd1; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd21; end 
                    6'd2: begin a_sel=5'd2; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd22; end 
                    6'd3: begin a_sel=5'd3; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd23; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd19: begin // LOAD A TO BASE
                case (step_counter)
                    6'd0: begin a_sel=5'd0; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd4; end 
                    6'd1: begin a_sel=5'd1; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd5; end 
                    6'd2: begin a_sel=5'd2; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd6; end 
                    6'd3: begin a_sel=5'd3; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd7; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd20: begin // LOAD R TO BASE
                case (step_counter)
                    6'd0: begin a_sel=5'd20; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd4; end 
                    6'd1: begin a_sel=5'd21; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd5; end 
                    6'd2: begin a_sel=5'd22; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd6; end 
                    6'd3: begin a_sel=5'd23; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd7; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd21: begin // VERIFY X
                mod_p_en = 1'b1;
                case (step_counter)
                    6'd0: begin a_sel=5'd17; b_sel=5'd2;  rom_alu_op=OP_MULT; dest_sel=5'd14; end 
                    6'd1: begin a_sel=5'd0;  b_sel=5'd19; rom_alu_op=OP_MULT; dest_sel=5'd15; end 
                    6'd2: begin a_sel=5'd14; b_sel=5'd15; rom_alu_op=OP_CMP;  dest_sel=5'd14; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd22: begin // VERIFY Y
                mod_p_en = 1'b1;
                case (step_counter)
                    6'd0: begin a_sel=5'd18; b_sel=5'd2;  rom_alu_op=OP_MULT; dest_sel=5'd14; end 
                    6'd1: begin a_sel=5'd1;  b_sel=5'd19; rom_alu_op=OP_MULT; dest_sel=5'd15; end 
                    6'd2: begin a_sel=5'd14; b_sel=5'd15; rom_alu_op=OP_CMP;  dest_sel=5'd14; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            5'd23: begin // EXPORT H SCALAR
                case (step_counter)
                    6'd0: begin a_sel=5'd16; b_sel=5'd0; rom_alu_op=OP_PASS; dest_sel=5'd16; rom_is_last_step=1'b1; end 
                    default: rom_is_last_step=1'b1;
                endcase
            end

            default: rom_is_last_step = 1'b1;
        endcase
    end

    assign alu_op = rom_alu_op;
    assign mult_kick = (sub_step == S_WAIT_DROP);
endmodule