module top_ed25519 (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start_verify,
    
    // External Data Inputs (Driven by Testbench or Host CPU)
    input  logic [255:0] ext_data_1, 
    input  logic [255:0] ext_data_2, 
    input  logic [255:0] otp_data,
    input  logic [1:0]   data_sel,
    
    input  logic         ext_we,
    input  logic [4:0]   ext_dest_sel,
    
    // Verification Verdict
    output logic         verify_done,    
    output logic         signature_valid
);

    // --- Internal Traces (Wires) ---
    logic [4:0]   a_sel, b_sel, dest_sel, seq_id;
    logic         start_seq, reg_we, sel_hi, cmp_flag, cmp_eq, mult_done, seq_done;
    logic [2:0]   alu_op;
    logic [255:0] src_a, src_b, alu_result;
    logic         mult_kick;
    logic         mod_p_en;     
    logic [255:0] reg_write_data; 
    
    // Floating x_sign wire (used internally between alu_top and the conditional logic)
    logic         x_sign; 
    logic final_we;
    logic [4:0] final_dest_sel;

    // Allow host to write only when FSM is IDLE
    assign final_we = (u_fsm.state == 6'd0) ? ext_we : reg_we; 
    assign final_dest_sel = (u_fsm.state == 6'd0) ? ext_dest_sel : dest_sel;
    // --- The Master Orchestrator ---
    master_fsm u_fsm (
        .clk                (clk),
        .rst_n              (rst_n),
        .start_verify       (start_verify),
        .verify_done        (verify_done),
        .signature_valid    (signature_valid),
        .start_seq          (start_seq),
        .seq_id             (seq_id),
        .seq_done           (seq_done),
        .datapath_read_data (src_a),   // Tapped directly off RegFile Port A
        .cmp_eq             (cmp_eq)
    );

    // --- The Micro-Code Sequencer ---
    micro_sequencer u_seq (
        .clk        (clk),
        .rst_n      (rst_n),
        .start_seq  (start_seq),
        .seq_id     (seq_id),
        .mult_done  (mult_done),
        .cmp_flag   (cmp_flag),
        .a_sel      (a_sel),
        .b_sel      (b_sel),
        .dest_sel   (dest_sel),
        .reg_we     (reg_we),
        .seq_done   (seq_done),        
        .alu_op     (alu_op),
        .mult_kick  (mult_kick),
        .sel_hi     (sel_hi),
        .mod_p_en   (mod_p_en)        
    );

    // --- Data Selection Multiplexer ---
    always_comb begin
        case (data_sel)
            2'b00: reg_write_data = alu_result;
            2'b01: reg_write_data = ext_data_1; 
            2'b10: reg_write_data = ext_data_2; 
            2'b11: reg_write_data = otp_data;   
            default: reg_write_data = alu_result;
        endcase
    end

    // --- The Dual-Port Register File ---
    reg_file u_regs (
        .clk        (clk),        
        .wr_enable  (final_we),
        .wr_addr    (final_dest_sel),
        .data_in    (reg_write_data), 
        .A_select   (a_sel),
        .A_out      (src_a),
        .B_select   (b_sel),
        .B_out      (src_b)
    );

    // --- The 256-Bit Datapath / Math Engine ---
    alu_top u_alu (
        .clk        (clk),
        .rst_n      (rst_n),
        .src_a      (src_a),
        .src_b      (src_b),
        .alu_op     (alu_op),
        .sel_hi     (sel_hi),
        .mod_p_en   (mod_p_en), 
        .alu_result (alu_result),
        .cmp_flag   (cmp_flag),
        .cmp_eq     (cmp_eq),
        .mult_done  (mult_done),
        .mult_kick  (mult_kick),
        .x_sign     (x_sign)     
    );

endmodule