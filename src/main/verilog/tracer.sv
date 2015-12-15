// See LICENSE for license details.

module tracer
  (
   input clk,
   input rstn,

   input valid,
   input [63:0] pc,
   input [31:0] inst,
   input [0:0] jmp,
   output ready,

   input rxd,
   output txd
   );

   localparam DEPTH = 4096;
   //localparam DEPTH = 64;
   
   // FIFO
   logic [63:0] fifo_pc [0:DEPTH-1];
   logic [31:0] fifo_inst [0:DEPTH-1];
   logic [0:0]  fifo_jmp [0:DEPTH-1];
   logic [63:0] fifo_pc_out;
   logic [31:0] fifo_inst_out;
   logic [0:0]  fifo_jmp_out;
   logic [15:0] wp, rp;
   logic        fifo_valid;

   // trace
   logic        trace_read;
   logic [4*27-1:0] trace;

   // UART AXI
   logic [31:0] w_data, r_data;
   logic        aw_valid, ar_valid, w_valid, r_valid, b_valid;
   logic        aw_ready, ar_ready, w_ready, r_ready, b_ready;
   logic        aw_sent, w_sent;
   
   enum integer { S_IDLE, S_CHECK_REQ, S_CHECK_RESP, S_SEND_REQ, S_SEND_RESP } state;
   integer cnt;

   // FIFO write
   assign ready = !fifo_valid || wp != rp;

   always_ff @(posedge clk) begin
      fifo_pc_out <= fifo_pc[rp];
      fifo_inst_out <= fifo_inst[rp];
      fifo_jmp_out <= fifo_jmp[rp];
      if(valid && ready) begin
         fifo_pc[wp] <= pc;
         fifo_inst[wp] <= inst;
         fifo_jmp[wp] <= jmp;
      end
   end

   always_ff @(posedge clk or negedge rstn)
     if(!rstn)
        wp <= 0;
     else begin
        if(valid && ready) begin
           if(wp != DEPTH-1) wp <= wp + 1;
           else              wp <= 0;
        end
     end

   always_ff @(posedge clk) begin
      trace_read <= state == S_IDLE && fifo_valid && cnt == 0;
      if(trace_read)
        trace <= {fifo_pc_out, 4'h0, fifo_inst_out, 7'h0, fifo_jmp_out};
   end

   // FIFO read
   always_ff @(posedge clk or negedge rstn)
     if(!rstn) begin
        rp <= 0;
        fifo_valid <= 0;
     end else if(state == S_IDLE && fifo_valid && cnt == 0) begin
        if(rp != DEPTH-1) begin
           rp <= rp + 1;
           if(wp == rp + 1 && !valid) fifo_valid <= 0;
        end else begin
           rp <= 0;
           if(wp == 0 && !valid) fifo_valid <= 0;
        end
     end else if(!fifo_valid && valid)
       fifo_valid <= 1;

   always_ff @(posedge clk or negedge rstn)
     if(!rstn)
        state <= S_IDLE;
     else begin
        case (state)
          S_IDLE: begin
             if(fifo_valid) state <= S_CHECK_REQ;
          end
          S_CHECK_REQ: begin
             if(ar_ready) state <= S_CHECK_RESP;
          end
          S_CHECK_RESP: begin
             if(r_valid) begin
                if(r_data[3]) state <= S_CHECK_REQ; // TX full
                else          state <= S_SEND_REQ;
             end
          end
          S_SEND_REQ: begin
             if((aw_ready || aw_sent) && (w_ready || w_sent))
               state <= S_SEND_RESP;
          end
          S_SEND_RESP: begin
             if(b_valid) state <= S_IDLE;
          end
          default:
            state <= S_IDLE;
        endcase // case (state)
     end

   always_ff @(posedge clk or negedge rstn)
     if(!rstn)
       cnt <= 0;
     else if(state == S_SEND_RESP && b_valid) begin
        if(cnt == 27) begin
           cnt <= 0;
        end else
          cnt <= cnt + 1;
     end 

   always_ff @(posedge clk)
     if(state == S_IDLE) begin
        aw_sent <= 0;
        w_sent <= 0;
     end else if(state == S_SEND_REQ) begin
        aw_sent <= aw_sent || aw_ready;
        w_sent <= w_sent || w_ready;
     end

   assign ar_valid = state == S_CHECK_REQ;
   assign aw_valid = state == S_SEND_REQ && !aw_sent;
   assign w_valid = state == S_SEND_REQ && !w_sent;
   assign r_ready = state == S_CHECK_RESP;
   assign b_ready = state == S_SEND_RESP;

   function logic [7:0] ascii_hex(input logic [3:0] d);
      case(d)
        0: return 8'h30;
        1: return 8'h31;
        2: return 8'h32;
        3: return 8'h33;
        4: return 8'h34;
        5: return 8'h35;
        6: return 8'h36;
        7: return 8'h37;
        8: return 8'h38;
        9: return 8'h39;
        10: return 8'h61;
        11: return 8'h62;
        12: return 8'h63;
        13: return 8'h64;
        14: return 8'h65;
        default: return 8'h66;
      endcase // case (d)
   endfunction // ascii_hex
   
   always_comb
     if(cnt < 16)
       w_data = ascii_hex(trace[(26-cnt)*4 +: 4]);
     else if(cnt == 16)
       w_data = 8'h20;
     else if(cnt < 25)
       w_data = ascii_hex(trace[(26-cnt)*4 +: 4]);
     else if(cnt == 25)
       w_data = 8'h20;
     else if(cnt < 27)
       w_data = ascii_hex(trace[(26-cnt)*4 +: 4]);
     else
       w_data = 8'h0a;

   axi_uartlite_0 tracer_uart
     (
      .s_axi_aclk      ( clk      ),
      .s_axi_aresetn   ( rstn     ),
      .s_axi_awaddr    ( 4'h04    ),
      .s_axi_awvalid   ( aw_valid ),
      .s_axi_awready   ( aw_ready ),
      .s_axi_wdata     ( w_data   ),
      .s_axi_wstrb     ( 4'b1     ),
      .s_axi_wvalid    ( w_valid  ),
      .s_axi_wready    ( w_ready  ),
      .s_axi_bvalid    ( b_valid  ),
      .s_axi_bready    ( b_ready  ),
      .s_axi_araddr    ( 4'h08    ),
      .s_axi_arvalid   ( ar_valid ),
      .s_axi_arready   ( ar_ready ),
      .s_axi_rdata     ( r_data   ),
      .s_axi_rvalid    ( r_valid  ),
      .s_axi_rready    ( r_ready  ),
      .rx              ( rxd      ),
      .tx              ( txd      )
      );

endmodule // tracer
