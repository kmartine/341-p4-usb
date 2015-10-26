// Constants for packet sizes - info bytes + sync
`define TOK_S 7'd28
`define HANDSHAKE_S 7'd12
`define DATA_S 7'd92

module nrzi(clk, rst_b, 
            bstr_in, bstr_in_ready, p_type,
            bstr_out, bstr_out_ready);

    input bit clk, rst_b, bstr_in, bstr_in_ready;
    input bit [1:0] p_type;
    output bit bstr_out, bstr_out_ready;

    logic use_nrzi;
    nrzi_ctrl ctrl (.*);

    // calculate the nrzi value if you're supposed to
    reg nrzi_val;
    reg bstr_out_ready_r;
    always_ff @(posedge clk, negedge rst_b) begin
        if (~rst_b) nrzi_val <= 1'b1;
        else        nrzi_val <= (~use_nrzi) ? 1'b1 : (bstr_in) ? nrzi_val : ~nrzi_val;
        bstr_out_ready_r <= bstr_in_ready;
    end

    assign bstr_out = (use_nrzi) ? nrzi_val : bstr_in,
           bstr_out_ready = bstr_out_ready_r;

endmodule

/*
 * determines when it's appropriate to use the nrzi encoding.
 * given a packet type, counts clk cycles 
 */
module nrzi_ctrl(clk, rst_b,
                 bstr_in_ready, p_type,
                 use_nrzi);

    input logic clk, rst_b;
    input bit bstr_in_ready;
    input logic [1:0] p_type;
    output logic use_nrzi;
 
    // decide what counter's limit should be;
    logic [6:0] counter_lim;
    always_comb
        case(p_type)
            2'b0: counter_lim = 7'b0;
            2'b01: counter_lim = `TOK_S;
            2'b10: counter_lim = `DATA_S;
            2'b11: counter_lim = `HANDSHAKE_S;
        endcase

    // increment counter if there's data    
    reg [6:0] counter;
    bit [6:0] count_in;
    always_comb begin
        if (~bstr_in_ready)
            count_in = 7'b0;
        else begin
            count_in = counter + 1;
        end
    end

    always_ff @(posedge clk, negedge rst_b) begin
        if (~rst_b) counter <= 7'b0;
        else        counter <= count_in;
    end

    // use nrzi if we are in the packet data
    always_comb begin
        if (bstr_in_ready && (counter < `TOK_S))
            use_nrzi = 1'b1;
        else use_nrzi = 1'b0;
    end

endmodule