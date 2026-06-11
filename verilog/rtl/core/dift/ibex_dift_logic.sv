`timescale 1ns/1ps

import ibex_pkg::*; // change to ibex_pkg

module ibex_dift_logic
(
  // Propagation Interface
  input  logic [ALU_MODE_WIDTH-1:0] operator_i,      // From Tag Propagation Register
  input  logic                      operand_a_tag_i, // Tag of Source 1
  input  logic                      operand_b_tag_i, // Tag of Source 2
  input  logic                      instr_tag_i,    // Tag of the instruction 
  
  // Check Interface
  input  logic                      check_s1_i,      // Enable check for Source 1
  input  logic                      check_s2_i,      // Enable check for Source 2
  input  logic                      check_d_i,       // Enable check for Destination
  input  logic                      is_load_i,       // Bypass check if instruction is LOAD
  
  // Outputs
  output logic                      result_tag_o,    // Calculated tag for result
  output logic                      rf_enable_tag_o, // Enable writing tag to RegFile
  output logic                      pc_enable_tag_o, // Enable tag update for PC
  output logic                      exception_o      // DIFT Violation Exception
);

// Propagation Logic, Check Logic 
  always_comb begin
    result_tag_o    = 1'b0;
    rf_enable_tag_o = 1'b1;
    pc_enable_tag_o = 1'b1;
    exception_o     = 1'b0;

    unique case (operator_i)
      ALU_MODE_OLD: begin
        rf_enable_tag_o = 1'b0;
        pc_enable_tag_o = 1'b0;
      end
      ALU_MODE_AND:   result_tag_o = operand_a_tag_i & operand_b_tag_i;
      ALU_MODE_OR:    result_tag_o = operand_a_tag_i | operand_b_tag_i;
      ALU_MODE_CLEAR: result_tag_o = 1'b0;
      default:        result_tag_o = 1'b0;
    endcase

    // PC/control-flow taint always propagates into result when mode is active
    //if (rf_enable_tag_o) begin
      //result_tag_o = result_tag_o | instr_tag_i;
    //end

    // Check logic: exception if policy bit set AND tag is present
    // Loads bypass this check because they are the source of tags, not the consumer; their tag checks are handled separately in the load check unit.
    if (~is_load_i) begin
      exception_o = (operand_a_tag_i & check_s1_i) ||
                    (operand_b_tag_i & check_s2_i) ||
                    (result_tag_o    & check_d_i);
    end
  end

endmodule