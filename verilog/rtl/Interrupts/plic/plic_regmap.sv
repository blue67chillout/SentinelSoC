module plic_regs #(
  parameter type reg_req_t  = logic,
  parameter type reg_rsp_t  = logic
)(
  input logic [12:0][1:0] prio_i,
  output logic [12:0][1:0] prio_o,
  output logic [12:0] prio_we_o,
  output logic [12:0] prio_re_o,
  input logic [0:0][12:0] ip_i,
  output logic [0:0] ip_re_o,
  input logic [0:0][12:0] ie_i,
  output logic [0:0][12:0] ie_o,
  output logic [0:0] ie_we_o,
  output logic [0:0] ie_re_o,
  input logic [0:0][1:0] threshold_i,
  output logic [0:0][1:0] threshold_o,
  output logic [0:0] threshold_we_o,
  output logic [0:0] threshold_re_o,
  input logic [0:0][3:0] cc_i,
  output logic [0:0][3:0] cc_o,
  output logic [0:0] cc_we_o,
  output logic [0:0] cc_re_o,
  // Bus Interface
  input  reg_req_t req_i,
  output reg_rsp_t resp_o
);
always_comb begin
  resp_o.ready = 1'b1;
  resp_o.rdata = '0;
  resp_o.error = '0;
  prio_o = '0;
  prio_we_o = '0;
  prio_re_o = '0;
  ie_o = '0;
  ie_we_o = '0;
  ie_re_o = '0;
  threshold_o = '0;
  threshold_we_o = '0;
  threshold_re_o = '0;
  cc_o = '0;
  cc_we_o = '0;
  cc_re_o = '0;
  if (req_i.valid) begin
    if (req_i.write) begin
      unique case(req_i.addr)
        32'hc000000: begin
          prio_o[0][1:0] = req_i.wdata[1:0];
          prio_we_o[0] = 1'b1;
        end
        32'hc000004: begin
          prio_o[1][1:0] = req_i.wdata[1:0];
          prio_we_o[1] = 1'b1;
        end
        32'hc000008: begin
          prio_o[2][1:0] = req_i.wdata[1:0];
          prio_we_o[2] = 1'b1;
        end
        32'hc00000c: begin
          prio_o[3][1:0] = req_i.wdata[1:0];
          prio_we_o[3] = 1'b1;
        end
        32'hc000010: begin
          prio_o[4][1:0] = req_i.wdata[1:0];
          prio_we_o[4] = 1'b1;
        end
        32'hc000014: begin
          prio_o[5][1:0] = req_i.wdata[1:0];
          prio_we_o[5] = 1'b1;
        end
        32'hc000018: begin
          prio_o[6][1:0] = req_i.wdata[1:0];
          prio_we_o[6] = 1'b1;
        end
        32'hc00001c: begin
          prio_o[7][1:0] = req_i.wdata[1:0];
          prio_we_o[7] = 1'b1;
        end
        32'hc000020: begin
          prio_o[8][1:0] = req_i.wdata[1:0];
          prio_we_o[8] = 1'b1;
        end
        32'hc000024: begin
          prio_o[9][1:0] = req_i.wdata[1:0];
          prio_we_o[9] = 1'b1;
        end
        32'hc000028: begin
          prio_o[10][1:0] = req_i.wdata[1:0];
          prio_we_o[10] = 1'b1;
        end
        32'hc00002c: begin
          prio_o[11][1:0] = req_i.wdata[1:0];
          prio_we_o[11] = 1'b1;
        end
        32'hc000030: begin
          prio_o[12][1:0] = req_i.wdata[1:0];
          prio_we_o[12] = 1'b1;
        end
        32'hc002000: begin
          ie_o[0][12:0] = req_i.wdata[12:0];
          ie_we_o[0] = 1'b1;
        end
        32'hc200000: begin
          threshold_o[0][1:0] = req_i.wdata[1:0];
          threshold_we_o[0] = 1'b1;
        end
        32'hc200004: begin
          cc_o[0][3:0] = req_i.wdata[3:0];
          cc_we_o[0] = 1'b1;
        end
        default: resp_o.error = 1'b1;
      endcase
    end else begin
      unique case(req_i.addr)
        32'hc000000: begin
          resp_o.rdata[1:0] = prio_i[0][1:0];
          prio_re_o[0] = 1'b1;
        end
        32'hc000004: begin
          resp_o.rdata[1:0] = prio_i[1][1:0];
          prio_re_o[1] = 1'b1;
        end
        32'hc000008: begin
          resp_o.rdata[1:0] = prio_i[2][1:0];
          prio_re_o[2] = 1'b1;
        end
        32'hc00000c: begin
          resp_o.rdata[1:0] = prio_i[3][1:0];
          prio_re_o[3] = 1'b1;
        end
        32'hc000010: begin
          resp_o.rdata[1:0] = prio_i[4][1:0];
          prio_re_o[4] = 1'b1;
        end
        32'hc000014: begin
          resp_o.rdata[1:0] = prio_i[5][1:0];
          prio_re_o[5] = 1'b1;
        end
        32'hc000018: begin
          resp_o.rdata[1:0] = prio_i[6][1:0];
          prio_re_o[6] = 1'b1;
        end
        32'hc00001c: begin
          resp_o.rdata[1:0] = prio_i[7][1:0];
          prio_re_o[7] = 1'b1;
        end
        32'hc000020: begin
          resp_o.rdata[1:0] = prio_i[8][1:0];
          prio_re_o[8] = 1'b1;
        end
        32'hc000024: begin
          resp_o.rdata[1:0] = prio_i[9][1:0];
          prio_re_o[9] = 1'b1;
        end
        32'hc000028: begin
          resp_o.rdata[1:0] = prio_i[10][1:0];
          prio_re_o[10] = 1'b1;
        end
        32'hc00002c: begin
          resp_o.rdata[1:0] = prio_i[11][1:0];
          prio_re_o[11] = 1'b1;
        end
        32'hc000030: begin
          resp_o.rdata[1:0] = prio_i[12][1:0];
          prio_re_o[12] = 1'b1;
        end
        32'hc001000: begin
          resp_o.rdata[12:0] = ip_i[0][12:0];
          ip_re_o[0] = 1'b1;
        end
        32'hc002000: begin
          resp_o.rdata[12:0] = ie_i[0][12:0];
          ie_re_o[0] = 1'b1;
        end
        32'hc200000: begin
          resp_o.rdata[1:0] = threshold_i[0][1:0];
          threshold_re_o[0] = 1'b1;
        end
        32'hc200004: begin
          resp_o.rdata[3:0] = cc_i[0][3:0];
          cc_re_o[0] = 1'b1;
        end
        default: resp_o.error = 1'b1;
      endcase
    end
  end
end
endmodule