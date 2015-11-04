// Handshake constants
`define HS_ACK 19'h014b
`define HS_NAK 19'h015a

`define SYNC 8'b00000001

// Transistion Status Constants
`define TRANS_NON 2'b00
`define TRANS_IN  2'b01
`define TRANS_OUT 2'b10

// Time Constants
`define TIMEOUT_LEN 8'd255

/*
 * protocol:
 * - gets transaction type from rw, 
 * - uses either in or out control fsm
 * - passes data around according to control pts
 */
module protocol(clk, rst_b,
                transaction, data_from_rw_avail,
                data_from_rw, token_from_rw,
                data_to_rw, data_to_rw_avail,
                pkt_sent, pkt_succeeded,
                pkt_done, enc_ready,
                pkt_to_enc, pkt_to_enc_avail,
                pkt_from_dec, pkt_from_dec_avail,
                pkt_from_dec_corrupt, re 
                );

    input logic clk, rst_b;

    // PROTOCOL <--> RW
    input [1:0] transaction;
    input logic data_from_rw_avail;
    input logic [18:0] token_from_rw;
    input logic [71:0] data_from_rw;
    output logic [63:0] data_to_rw;
    output logic data_to_rw_avail;
    output logic pkt_done, pkt_sent, pkt_succeeded;

    // PROTOCOL --> ENCODING
    input logic enc_ready;
    output logic [98:0] pkt_to_enc;
    output logic pkt_to_enc_avail;

    // DECODING --> PROTOCOL
    input logic [98:0] pkt_from_dec;
    input logic pkt_from_dec_avail;
    input logic pkt_from_dec_corrupt;

    // PROTOCOL --> DPDM
    output logic re;

    // CONTROL FSMS
    logic do_in; 
    assign do_in = (transaction == `TRANS_IN);
    logic do_out;
    assign do_out = (transaction == `TRANS_OUT);

    logic recieved_nak;
    logic in_done, in_success, send_hs, in_data_to_enc_avail, in_re;
    logic out_done, out_success, send_token,out_data_to_enc_avail, out_re;

    in_ctrl  ic (clk, rst_b, do_in, data_from_rw_avail,
                 enc_ready, pkt_from_dec_avail, pkt_from_dec_corrupt,
                 in_done, in_success, send_hs, in_data_to_enc_avail, in_re);
    out_ctrl oc (clk, rst_b, do_out, data_from_rw_avail,
                 enc_ready, pkt_from_dec_avail, pkt_from_dec_corrupt,
                 recieved_nak, out_done, out_success, out_data_to_enc_avail, send_token, out_re);

    assign re = (do_out) ? out_re : in_re;
    assign pkt_succeeded = (do_out) ? out_success : in_success;
    assign pkt_sent = (do_out) ? out_done : in_done;
    assign pkt_to_enc_avail = (do_out) ? out_data_to_enc_avail : in_data_to_enc_avail;
    assign pkt_done = (do_out) ? out_done : in_done;

    // PKT MANAGEMENT
    assign recieved_nak = (pkt_from_dec_avail) ? (pkt_from_dec[17:0] == `HS_NAK) : 0;
    assign data_to_rw = pkt_from_dec[81:18];

    logic [98:0] pkt_from_rw;
    assign pkt_from_rw = {`SYNC, data_from_rw}; 

    always_comb begin
        case(transaction)
            `TRANS_NON: begin
                pkt_to_enc = 0;
            end
            `TRANS_IN: begin
                pkt_to_enc = (~send_hs) ? token_from_rw : (pkt_succeeded) ? `HS_ACK : `HS_NAK;
            end
            `TRANS_OUT: begin
                pkt_to_enc = (send_token) ? token_from_rw : pkt_from_rw;
            end
        endcase
    end        

endmodule: protocol

/*
 * out_ctrl:
 * - start when given a transaction
 * - if done, got either an ack or a final nak
 * - if success, got an ack
 */
module out_ctrl(clk, rst_b,
                start, data_from_rw_avail,
                enc_ready, pkt_from_dec_avail,
                pkt_from_dec_corrupt,
                recieved_nak,
                done, success, data_to_enc_avail, send_token, re);

    input logic clk, rst_b, start, data_from_rw_avail,
                enc_ready, pkt_from_dec_avail,
                pkt_from_dec_corrupt,
                recieved_nak;
    output logic done, success, data_to_enc_avail, send_token, re;

    logic pkt_sent, retry, timeout;
    logic data_recieved;
    logic [7:0] counter;

    assign data_recieved = ~recieved_nak && ~pkt_from_dec_corrupt && ~timeout;

    // STATE TRANSISTIONS
    enum logic [1:0] {idle = 2'b00,
                      token = 2'b01,
                      data = 2'b10,
                      hs = 2'b11} state, nextState;

    always_comb begin
        case(state)
            idle: nextState = (start && data_from_rw_avail) ? token : idle;
            token: nextState = (pkt_sent) ? data : token;
            data: nextState = (pkt_sent) ? hs : data;
            hs: nextState = (data_recieved) ? idle : (retry) ? data : idle;
        endcase
    end

    always_ff @(posedge clk, negedge rst_b) begin
        if (~rst_b) state <= idle;
        else        state <= nextState;
    end

    // TIMEOUT
    logic en, rst;
    assign en = (state == hs);
    assign rst = ~en;
    timeout to (clk, rst_b, en, rst, timeout);

    // STATUS POINTS

    // pkt_sent: was encoder ready when we tried to send last packet
    always_ff @(posedge clk, negedge rst_b) begin
        if (~rst_b) pkt_sent <= 1;
        else        pkt_sent <= enc_ready;
    end

    // retry: try to send packet again?
    always_ff @(posedge clk, negedge rst_b) begin
        if (~rst_b) retry <= 1;
        else        retry <= (state == hs && ~data_recieved && counter < 7);
    end

    // counter: track number of naks recieved
    always_ff @(posedge clk, negedge rst_b) begin
        if (~rst_b) counter <= 0;
        else        counter <= (state == idle) ? 0 : (retry) ? counter + 1 : counter;
    end

    assign done = (state == hs && nextState == idle);
    assign success = (done & data_recieved);
    assign send_token = (state == token);
    assign data_to_enc_avail = (state == token || state == data);
    assign re = (state == hs);

endmodule: out_ctrl

/*
 * in_ctrl:
 * - start when given a transaction
 * - if done, give up sending naks or send an ack
 * - if success, send ack
 * - if send_hs, send ack or nak
 */
module in_ctrl(clk, rst_b,
               start,
               data_avail, enc_ready,
               pkt_from_dec_avail,
               pkt_from_dec_corrupt,
               done, success, send_hs, data_to_enc_avail, re); 

    input logic clk, rst_b,
                start, data_avail,
                enc_ready,
                pkt_from_dec_avail,
                pkt_from_dec_corrupt;
    output logic done, success, send_hs, data_to_enc_avail, re;
                
    logic pkt_sent, retry, pkt_good, timeout;
    logic [7:0] counter;

    // STATE TRANSISTIONS
    enum logic [1:0] {idle  = 2'b00,
                      token = 2'b01,
                      data  = 2'b10,
                      hs    = 2'b11} state, nextState;

    always_comb begin
        case(state)
            idle:  nextState = (start && data_avail) ? token : idle;
            token: nextState = (pkt_sent) ? data : token;
            data:  nextState = (pkt_from_dec_avail || timeout) ? hs : data;
            hs:    nextState = (~pkt_sent) ? hs : (retry) ? data : idle;
        endcase
    end

    always_ff @(posedge clk, negedge rst_b) begin
        if (~rst_b) state <= idle;
        else        state <= nextState;
    end

    // TIMEOUT
    logic en, rst;
    assign en = (state == data);
    assign rst = (state == idle);
    timeout to (clk, rst_b, en, rst, timeout);

    // STATUS POINTS

    // pkt_sent: was the encoder ready last time we tried to send
    always_ff @(posedge clk, negedge rst_b) begin
        if (~rst_b) pkt_sent <= 0;
        else        pkt_sent <= enc_ready;
    end

    // counter: how many times have we retried
    always_ff @(posedge clk, negedge rst_b) begin
        if (~rst_b) counter <= 0;
        else        counter <= (state == idle) ? 0 : (retry) ? counter + 1 : counter;
    end

    // retry: should we wait for data again
    always_ff @(posedge clk, negedge rst_b) begin
        if (~rst_b) retry <= 0;
        else retry <= (state == data && pkt_from_dec_corrupt && counter < 8); 
    end

    // pkt_good: 
    always_ff @(posedge clk, negedge rst_b) begin
        if (~rst_b) pkt_good <= 0;
        else        pkt_good <= ((state == data && ~pkt_from_dec_corrupt) && ~timeout);
    end

    // CONTROL SIGNALS
    assign re = (state == data);
    assign done = (state == hs && nextState == idle);
    assign success = (done && pkt_good);
    assign send_hs = (state == hs);
    assign data_to_enc_avail = (state == hs || state == token);

endmodule: in_ctrl

module timeout(clk, rst_b,
               en, rst,
               timeout);

    input logic clk, rst_b, en, rst;
    output logic timeout;

    logic [7:0] counter, counter_in;
    assign counter_in = (en) ? counter + 1 : 0;

    always_ff @(posedge clk, negedge rst_b) begin
        if (~rst_b) counter <= 0;
        else        counter <= (rst) ? 0 : counter_in;
    end

    assign timeout = (counter == `TIMEOUT_LEN);
endmodule: timeout
