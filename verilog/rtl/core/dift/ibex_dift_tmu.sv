////////////////////////////////////////////////////////////////////////////////
// Combined Tag Management Units for DIFT Implementation                      //
//                                                                            //
// This file contains:                                                        //
// 1. riscv_check_tag: Reads TCR and decodes signals for EX stage.            //
// 2. riscv_load_check: Raises exceptions based on LOAD tag policies.         //
// 3. riscv_load_propagation: Computes destination tags for LOAD operations.  //
// 4. riscv_mode_tag: Decodes TPR MODE fields for EX stage.                   //
// 5. riscv_enable_tag: Decodes TPR ENABLE fields for ID stage.               //
////////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

import ibex_pkg::*;

// --- MODULE 1: CHECK TAG DECODER ---
module ibex_dift_tmu
(
  input  logic [31:0] instr_rdata_i,
  input  logic [31:0] tcr_i,
  output logic        source_1_o,
  output logic        source_2_o,
  output logic        dest_o,
  output logic        execute_pc_o
);

  always_comb
  begin
    source_1_o   = 1'b0;
    source_2_o   = 1'b0;
    dest_o       = 1'b0;
    execute_pc_o = tcr_i[EXECUTE_PC];

    unique case (instr_rdata_i[6:0])
      OPCODE_JAL,
      OPCODE_JALR: begin   // Jump and Link
        source_1_o = tcr_i[JUMP_CHECK_S1];
        source_2_o = tcr_i[JUMP_CHECK_S2];
        dest_o     = tcr_i[JUMP_CHECK_D];
      end

      OPCODE_BRANCH: begin // Branch
        source_1_o = tcr_i[BRANCH_CHECK_S1];
        source_2_o = tcr_i[BRANCH_CHECK_S2];
        dest_o     = 1'b0;
      end

      OPCODE_STORE,
      //OPCODE_STORE_POST,
      OPCODE_LUI,
      OPCODE_AUIPC
      : begin
        source_1_o = tcr_i[LOADSTORE_CHECK_DA];
        source_2_o = tcr_i[LOADSTORE_CHECK_S];
        dest_o     = tcr_i[LOADSTORE_CHECK_D];
      end

      OPCODE_OPIMM: begin
        unique case (instr_rdata_i[14:12])
          3'b000: begin  // ADDI
            source_1_o = tcr_i[INTEGER_CHECK_S1];
            source_2_o = tcr_i[INTEGER_CHECK_S2];
            dest_o     = tcr_i[INTEGER_CHECK_D];
          end
          3'b001: begin
            unique case (instr_rdata_i[31:25])
              7'b0000000: begin // SLLI
                source_1_o = tcr_i[SHIFT_CHECK_S1];
                source_2_o = tcr_i[SHIFT_CHECK_S2];
                dest_o     = tcr_i[SHIFT_CHECK_D];
              end
              default: ;
            endcase
          end
          3'b010, 3'b011: begin  // SLTI, SLTIU
            source_1_o = tcr_i[COMPARISON_CHECK_S1];
            source_2_o = tcr_i[COMPARISON_CHECK_S2];
            dest_o     = tcr_i[COMPARISON_CHECK_D];
          end
          3'b100, 3'b110, 3'b111: begin  // XORI, ORI, ANDI
            source_1_o = tcr_i[LOGICAL_CHECK_S1];
            source_2_o = tcr_i[LOGICAL_CHECK_S2];
            dest_o     = tcr_i[LOGICAL_CHECK_D];
          end
          3'b101: begin
            unique case (instr_rdata_i[31:25])
              7'b0000000, 7'b0100000: begin // SRLI, SRAI
                source_1_o = tcr_i[SHIFT_CHECK_S1];
                source_2_o = tcr_i[SHIFT_CHECK_S2];
                dest_o     = tcr_i[SHIFT_CHECK_D];
              end
              default: ;
            endcase
          end
          default: ;
        endcase
      end

      OPCODE_OP: begin
        unique case (instr_rdata_i[14:12])
          3'b000: begin
            unique case (instr_rdata_i[31:25])
              7'b0000000, 7'b0100000: begin // ADD, SUB
                source_1_o = tcr_i[INTEGER_CHECK_S1];
                source_2_o = tcr_i[INTEGER_CHECK_S2];
                dest_o     = tcr_i[INTEGER_CHECK_D];
              end
              7'b0000001: begin // MUL
                source_1_o = tcr_i[INTEGER_CHECK_S1];
                source_2_o = tcr_i[INTEGER_CHECK_S2];
                dest_o     = tcr_i[INTEGER_CHECK_D];
              end
              default: ;
            endcase
          end
          3'b001: begin
            unique case (instr_rdata_i[31:25])
              7'b0000000: begin // SLL
                source_1_o = tcr_i[SHIFT_CHECK_S1];
                source_2_o = tcr_i[SHIFT_CHECK_S2];
                dest_o     = tcr_i[SHIFT_CHECK_D];
              end
              7'b0000001: begin // MULH
                source_1_o = tcr_i[INTEGER_CHECK_S1];
                source_2_o = tcr_i[INTEGER_CHECK_S2];
                dest_o     = tcr_i[INTEGER_CHECK_D];
              end
              default: ;
            endcase
          end
          3'b010: begin
            unique case (instr_rdata_i[31:25])
              7'b0000000: begin // SLT
                source_1_o = tcr_i[COMPARISON_CHECK_S1];
                source_2_o = tcr_i[COMPARISON_CHECK_S2];
                dest_o     = tcr_i[COMPARISON_CHECK_D];
              end
              7'b0000001: begin // MULHSU
                source_1_o = tcr_i[INTEGER_CHECK_S1];
                source_2_o = tcr_i[INTEGER_CHECK_S2];
                dest_o     = tcr_i[INTEGER_CHECK_D];
              end
              default: ;
            endcase
          end
          3'b011: begin
            unique case (instr_rdata_i[31:25])
              7'b0000000: begin // SLTU
                source_1_o = tcr_i[COMPARISON_CHECK_S1];
                source_2_o = tcr_i[COMPARISON_CHECK_S2];
                dest_o     = tcr_i[COMPARISON_CHECK_D];
              end
              7'b0000001: begin // MULHU
                source_1_o = tcr_i[INTEGER_CHECK_S1];
                source_2_o = tcr_i[INTEGER_CHECK_S2];
                dest_o     = tcr_i[INTEGER_CHECK_D];
              end
              default: ;
            endcase
          end
          3'b100: begin
            unique case (instr_rdata_i[31:25])
              7'b0000000: begin // XOR
                source_1_o = tcr_i[LOGICAL_CHECK_S1];
                source_2_o = tcr_i[LOGICAL_CHECK_S2];
                dest_o     = tcr_i[LOGICAL_CHECK_D];
              end
              7'b0000001: begin // DIV
                source_1_o = tcr_i[INTEGER_CHECK_S1];
                source_2_o = tcr_i[INTEGER_CHECK_S2];
                dest_o     = tcr_i[INTEGER_CHECK_D];
              end
              default: ;
            endcase
          end
          3'b101: begin
            unique case (instr_rdata_i[31:25])
              7'b0000000, 7'b0100000: begin // SRL, SRA
                source_1_o = tcr_i[SHIFT_CHECK_S1];
                source_2_o = tcr_i[SHIFT_CHECK_S2];
                dest_o     = tcr_i[SHIFT_CHECK_D];
              end
              7'b0000001: begin // DIVU
                source_1_o = tcr_i[INTEGER_CHECK_S1];
                source_2_o = tcr_i[INTEGER_CHECK_S2];
                dest_o     = tcr_i[INTEGER_CHECK_D];
              end
              default: ;
            endcase
          end
          3'b110: begin
            unique case (instr_rdata_i[31:25])
              7'b0000000: begin // OR
                source_1_o = tcr_i[LOGICAL_CHECK_S1];
                source_2_o = tcr_i[LOGICAL_CHECK_S2];
                dest_o     = tcr_i[LOGICAL_CHECK_D];
              end
              7'b0000001: begin // REM
                source_1_o = tcr_i[INTEGER_CHECK_S1];
                source_2_o = tcr_i[INTEGER_CHECK_S2];
                dest_o     = tcr_i[INTEGER_CHECK_D];
              end
              default: ;
            endcase
          end
          3'b111: begin
            unique case (instr_rdata_i[31:25])
              7'b0000000: begin // AND
                source_1_o = tcr_i[LOGICAL_CHECK_S1];
                source_2_o = tcr_i[LOGICAL_CHECK_S2];
                dest_o     = tcr_i[LOGICAL_CHECK_D];
              end
              7'b0000001: begin // REMU
                source_1_o = tcr_i[INTEGER_CHECK_S1];
                source_2_o = tcr_i[INTEGER_CHECK_S2];
                dest_o     = tcr_i[INTEGER_CHECK_D];
              end
              default: ;
            endcase
          end
          default: ;
        endcase
      end
      default: ;
    endcase
  end
endmodule

// --- MODULE 2: LOAD CHECK UNIT ---
module riscv_load_check
(
  input  logic        regfile_wdata_wb_i_tag,
  input  logic        rs1_i_tag,
  input  logic        regfile_dest_tag,
  input  logic [31:0] tcr_i,
  input  logic        regfile_we_wb_i,
  output logic        exception_o
);

  logic  check_s;
  logic  check_sa;
  logic  check_d;

  assign check_s  = tcr_i[LOADSTORE_CHECK_S];
  assign check_sa = tcr_i[LOADSTORE_CHECK_SA];
  assign check_d  = tcr_i[LOADSTORE_CHECK_D];

  always_comb
  begin
    exception_o = 1'b0;
    if (regfile_we_wb_i) begin
      if ((regfile_wdata_wb_i_tag & check_s) || (rs1_i_tag & check_sa) || (regfile_dest_tag & check_d)) begin
        exception_o = 1'b1;
      end else begin
        exception_o = 1'b0;
      end
    end
  end
endmodule

// --- MODULE 3: LOAD PROPAGATION UNIT ---
module riscv_load_propagation
(
  input  logic        regfile_wdata_wb_i_tag,
  input  logic        rs1_i_tag,
  input  logic        regfile_we_wb_i,
  input  logic [31:0] tpr_i,
  output logic        regfile_dest_tag,
  output logic        regfile_enable_tag
);

  logic [ALU_MODE_WIDTH-1:0] alu_operator_mode;
  logic enable_a;
  logic enable_b;
  logic operand_a;
  logic operand_b;

  assign alu_operator_mode = tpr_i[LOADSTORE_HIGH:LOADSTORE_LOW];
  assign enable_a  = tpr_i[LOADSTORE_EN_SOURCE_ADDR];
  assign enable_b  = tpr_i[LOADSTORE_EN_SOURCE];
  assign operand_a = rs1_i_tag & enable_a;
  assign operand_b = regfile_wdata_wb_i_tag & enable_b;

  always_comb
  begin
    regfile_dest_tag     = 1'b0;
    regfile_enable_tag   = 1'b0;
    if (regfile_we_wb_i) begin
      regfile_dest_tag   = 1'b0;
      regfile_enable_tag = 1'b1;

      unique case (alu_operator_mode)
        ALU_MODE_OLD:   regfile_enable_tag = 1'b0;
        ALU_MODE_AND:   regfile_dest_tag = operand_a & operand_b;
        ALU_MODE_OR:    regfile_dest_tag = operand_a | operand_b;
        ALU_MODE_CLEAR: regfile_dest_tag = '0;
        default: ;
      endcase
    end
  end
endmodule

// --- MODULE 4: MODE TAG DECODER ---
module riscv_mode_tag
(
  input  logic [31:0] instr_rdata_i,
  input  logic [31:0] tpr_i,
  output logic [ALU_MODE_WIDTH-1:0] alu_operator_o_mode,
  output logic                      register_set_o,
  output logic                      is_store_post_o,
  output logic                      memory_set_o
);

  always_comb
  begin
    alu_operator_o_mode          = ALU_MODE_OLD;
    register_set_o               = 1'b0;
    memory_set_o                 = 1'b0;
    is_store_post_o               = 1'b0;

    unique case (instr_rdata_i[6:0])
      OPCODE_JAL,
      OPCODE_JALR: alu_operator_o_mode = tpr_i[JUMP_HIGH:JUMP_LOW];

      OPCODE_BRANCH: alu_operator_o_mode = tpr_i[BRANCH_HIGH:BRANCH_LOW];

      OPCODE_STORE: begin
        if(instr_rdata_i[14:12] == 3'b111) begin
          memory_set_o = 1'b1;
        end else begin
          alu_operator_o_mode = tpr_i[LOADSTORE_HIGH:LOADSTORE_LOW];
        end
      end

      //Non existent in current Ibex, but reserved for future use
      /*OPCODE_STORE_POST: begin
        alu_operator_o_mode = tpr_i[LOADSTORE_HIGH:LOADSTORE_LOW];
        is_store_post_o     = 1'b1;
      end*/

      OPCODE_LUI,
      OPCODE_AUIPC: alu_operator_o_mode = tpr_i[LOADSTORE_HIGH:LOADSTORE_LOW];

      OPCODE_LOAD: alu_operator_o_mode = ALU_MODE_OLD;

      OPCODE_OPIMM: begin
        unique case (instr_rdata_i[14:12])
          3'b000: alu_operator_o_mode = tpr_i[INTEGER_HIGH:INTEGER_LOW];
          3'b001: begin
            if(instr_rdata_i[31:25] == 7'b0000000)
              alu_operator_o_mode = tpr_i[SHIFT_HIGH:SHIFT_LOW];
          end
          3'b010, 3'b011: alu_operator_o_mode = tpr_i[COMPARISON_HIGH:COMPARISON_LOW];
          3'b100, 3'b110, 3'b111: alu_operator_o_mode = tpr_i[LOGICAL_HIGH:LOGICAL_LOW];
          3'b101: begin
            if(instr_rdata_i[31:25] == 7'b0000000 || instr_rdata_i[31:25] == 7'b0100000)
              alu_operator_o_mode = tpr_i[SHIFT_HIGH:SHIFT_LOW];
          end
          default: ;
        endcase
      end

      OPCODE_OP: begin
        if(instr_rdata_i[31:25] == 7'b1011010) begin
          register_set_o = 1'b1;
        end else begin
          unique case (instr_rdata_i[14:12])
            3'b000: alu_operator_o_mode = tpr_i[INTEGER_HIGH:INTEGER_LOW];
            3'b001: begin
              if(instr_rdata_i[31:25] == 7'b0000000) alu_operator_o_mode = tpr_i[SHIFT_HIGH:SHIFT_LOW];
              else if(instr_rdata_i[31:25] == 7'b0000001) alu_operator_o_mode = tpr_i[INTEGER_HIGH:INTEGER_LOW];
            end
            3'b010, 3'b011: alu_operator_o_mode = (instr_rdata_i[31:25] == 7'b0000000) ? tpr_i[COMPARISON_HIGH:COMPARISON_LOW] : tpr_i[INTEGER_HIGH:INTEGER_LOW];
            3'b100: alu_operator_o_mode = (instr_rdata_i[31:25] == 7'b0000000) ? tpr_i[LOGICAL_HIGH:LOGICAL_LOW] : tpr_i[INTEGER_HIGH:INTEGER_LOW];
            3'b101: alu_operator_o_mode = (instr_rdata_i[31:25] == 7'b0000001) ? tpr_i[INTEGER_HIGH:INTEGER_LOW] : tpr_i[SHIFT_HIGH:SHIFT_LOW];
            3'b110, 3'b111: alu_operator_o_mode = (instr_rdata_i[31:25] == 7'b0000000) ? tpr_i[LOGICAL_HIGH:LOGICAL_LOW] : tpr_i[INTEGER_HIGH:INTEGER_LOW];
            default: ;
          endcase
        end
      end
      default: ;
    endcase
  end
endmodule

// --- MODULE 5: ENABLE TAG DECODER ---
module riscv_enable_tag
(
  input  logic [31:0] instr_rdata_i,
  input  logic [31:0] tpr_i,
  output logic        is_store_o,
  output logic        enable_a_o,
  output logic        enable_b_o
);

  always_comb
  begin
    enable_a_o = 1'b0;
    enable_b_o = 1'b0;
    is_store_o = 1'b0;

    unique case (instr_rdata_i[6:0])
      OPCODE_STORE: begin
        enable_a_o  = tpr_i[LOADSTORE_EN_DEST_ADDR];
        enable_b_o  = tpr_i[LOADSTORE_EN_SOURCE];
        is_store_o  = 1'b1;
      end
      default: ;
    endcase
  end
endmodule