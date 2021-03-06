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
                pkt_done, pkt_succeeded, 
                pkt_sent, dec_ready,
                pkt_to_enc, pkt_to_enc_avail,
                pkt_from_dec, pkt_from_dec_avail,
                pkt_from_dec_corrupt 
                );

    input logic clk, rst_b;

    // PROTOCOL <--> RW
    input [1:0] transaction;
    input logic data_from_rw_avail;
    input logic [18:0] token_from_rw;
    input logic [71:0] data_from_rw;
    output logic [63:0] data_to_rw;
    output logic data_to_rw_avail;
    output logic pkt_done, pkt_succeeded;

    // PROTOCOL --> ENCODING
    input logic pkt_sent;
    output logic [98:0] pkt_to_enc;
    output logic pkt_to_enc_avail;

    // DECODING --> PROTOCOL
    input logic [98:0] pkt_from_dec;
    input logic pkt_from_dec_avail,
                pkt_from_dec_corrupt,
                dec_ready;

    // CONTROL FSMS
    logic do_in; 
    assign do_in = (transaction == `TRANS_IN);
    logic do_out;
    assign do_out = (transaction == `TRANS_OUT);

    logic got_ack, got_nak;
    logic in_done, in_success, send_hs, in_data_to_enc_avail;
    logic out_done, out_success, send_token,out_data_to_enc_avail;

    in_ctrl  ic (clk, rst_b, do_in, data_from_rw_avail,
                 pkt_sent, pkt_from_dec_avail, pkt_from_dec_corrupt,
                 in_done, in_success, send_hs, in_data_to_enc_avail);
    out_ctrl oc (clk, rst_b, do_out, data_from_rw_avail,
                 pkt_sent, pkt_from_dec_avail, pkt_from_dec_corrupt,
                 got_nak, got_ack, out_done, out_success, out_data_to_enc_avail, send_token);

    assign pkt_succeeded = (do_out) ? out_success : in_success;
    assign pkt_done = (do_out) ? out_done : in_done;
    assign pkt_to_enc_avail = (do_out) ? out_data_to_enc_avail : in_data_to_enc_avail;

    // PKT MANAGEMENT
    assign got_nak = (pkt_from_dec_avail) ? (pkt_from_dec[7:0] != 8'h4b) : 0;
    assign got_ack = (pkt_from_dec_avail) ? (pkt_from_dec[7:0] == 8'h4b) : 0;
    assign data_to_rw = pkt_from_dec[81:18];
    assign data_to_rw_avail = pkt_from_dec_avail;

    logic [98:0] pkt_from_rw;
    assign pkt_from_rw = {`SYNC, data_from_rw, 19'b0}; 

    always_comb begin
        case(transaction)
            `TRANS_NON: begin
                pkt_to_enc = 0;
            end
            `TRANS_IN: begin
                pkt_to_enc = (~send_hs) ? {`SYNC, token_from_rw, 72'b0} : (pkt_succeeded) ? {`HS_ACK, 83'd0} : {`HS_NAK, 83'd0};
            end
            `TRANS_OUT: begin
                pkt_to_enc = (send_token) ? {`SYNC, token_from_rw, 72'b0} : pkt_from_rw;
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
                pkt_sent, pkt_from_dec_avail,
                pkt_from_dec_corrupt,
                got_nak, got_ack,
                done, success, data_to_enc_avail, send_token);

    input logic clk, rst_b, start, data_from_rw_avail,
                pkt_from_dec_avail, pkt_sent,
                pkt_from_dec_corrupt,
                got_nak, got_ack;
    output logic done, success, data_to_enc_avail, send_token;

    logic retry, timeout;
    logic data_accepted;
    logic [7:0] counter;

    assign data_accepted = pkt_from_dec_avail && ~pkt_from_dec_corrupt && got_ack;

    // STATE TRANSISTIONS
    enum logic [2:0] {idle = 3'b000,
                      token = 3'b001,
                      data = 3'b010,
                      hs = 3'b011,
                      hold = 3'b100} state, nextState;

    always_comb begin
        case(state)
            idle: nextState = (start && data_from_rw_avail) ? token : idle;
            token: nextState = (pkt_sent) ? hold : token;
            hold: nextState = data;
            data: nextState = (pkt_sent) ? hs : data;
            hs: begin
                if (got_ack)
                    nextState = idle;
                if (timeout || got_nak)
                     nextState = (retry) ? data : idle;
                if (~timeout && ~pkt_from_dec_avail)
                    nextState = hs;
            end
        endcase
    end

    // TODO: hs advances too quickly 

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

    // retry: try to send packet again?
    assign retry = (timeout || got_nak) && (counter < 7);

    // counter: track number of naks recieved
    always_ff @(posedge clk, negedge rst_b) begin
        if (~rst_b) counter <= 0;
        else        counter <= (state == idle) ? 0 : (retry) ? counter + 1 : counter;
    end

    assign done = (state == hs && nextState == idle);
    assign success = (done & got_ack);
    assign send_token = (state == token);
    assign data_to_enc_avail = (state == token) || (state == data);

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
               done, success, send_hs, data_to_enc_avail); 

    input logic clk, rst_b,
                start, data_avail,
                enc_ready,
                pkt_from_dec_avail,
                pkt_from_dec_corrupt;
    output logic done, success, send_hs, data_to_enc_avail;
                
    logic pkt_sent, retry, pkt_good, timeout;
    logic [7:0] counter;

    // STATE TRANSISTIONS
    enum logic [2:0] {idle  = 3'b000,
                      token = 3'b001,
                      data  = 3'b010,
                      hs    = 3'b011,
                      hold  = 3'b100} state, nextState;

    always_comb begin
        case(state)
            idle:  nextState = (start && data_avail) ? token : idle;
            token: nextState = (pkt_sent) ? hold : token;
            hold: nextState = data;
            data: begin
                if (~timeout) begin
                    if (pkt_from_dec_avail)
                        nextState = hs;
                    else
                        nextState = data;
                end else begin
                    if (retry) 
                        nextState = data;
                    else
                        nextState = hs;
                end
            end
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
        else        pkt_good <= (state == data && ~pkt_from_dec_corrupt);
    end

    // CONTROL SIGNALS
    assign done = (state == hs && nextState == idle);
    assign success = (done && pkt_from_dec_avail && ~pkt_from_dec_corrupt);
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
