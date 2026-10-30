// ============================================================================
// tb_aes128_core : self-checking testbench for aes128_core
// ----------------------------------------------------------------------------
// Checks
//   1. Known-answer tests: FIPS-197 C.1 and Appendix B, all-zero key/block,
//      NIST SP 800-38A F.1.1 (ECB-AES128, 4 blocks).
//   2. 32 random key/plaintext pairs. Expected values were generated with the
//      Windows .NET AES (ECB) implementation; the Python golden model in
//      /model will replace this once Python is installed.
//   3. Latency is exactly 10 cycles from the accepting edge to done,
//      done is a 1-cycle pulse, ready is low while busy.
//   4. key / block_in change right after start: the result must not change.
//   5. start pulses while busy are ignored.
//   6. block_out holds its value after done.
//   7. Reset in the middle of a block aborts it (no done); the core works
//      afterwards.
//   8. Back-to-back blocks: one block every 11 cycles.
//   9. Every accepted start produces exactly one done.
// Stops with $fatal on the first mismatch, otherwise prints TEST PASSED.
// ============================================================================
`timescale 1ns/1ps

module tb_aes128_core;

    localparam int LATENCY = 10;    // edges from accepting edge to done
    localparam int PERIOD  = 11;    // cycles per block, back to back
    localparam int N_KAT   = 7;     // number of known-answer vectors

    logic         clk = 1'b0;
    logic         rst = 1'b1;
    logic         start = 1'b0;
    logic [127:0] key = '0;
    logic [127:0] block_in = '0;
    wire          ready;
    wire          done;
    wire  [127:0] block_out;

    aes128_core dut (
        .clk(clk), .rst(rst), .start(start), .key(key), .block_in(block_in),
        .ready(ready), .done(done), .block_out(block_out)
    );

    always #5 clk = ~clk;           // 100 MHz

    // --- start / done bookkeeping (check 9) ---------------------------------
    int n_accepted = 0;
    int n_done     = 0;
    always @(posedge clk) begin
        if (rst) begin
            n_accepted <= 0;
            n_done     <= 0;
        end else begin
            if (start && ready) n_accepted <= n_accepted + 1;
            if (done)           n_done     <= n_done + 1;
        end
    end

    // --- vector store --------------------------------------------------------
    logic [127:0] vk[$], vp[$], ve[$];
    string        vname[$];

    function automatic void add_vec(logic [127:0] k, logic [127:0] p, logic [127:0] e,
                                    string name = "random");
        vk.push_back(k); vp.push_back(p); ve.push_back(e); vname.push_back(name);
    endfunction

    function automatic logic [127:0] rand128();
        return {$urandom, $urandom, $urandom, $urandom};
    endfunction

    // --- one block, with protocol checks --------------------------------------
    // All driving and sampling happens on the falling edge.
    task automatic run_block(input logic [127:0] k, input logic [127:0] p,
                             input logic [127:0] e, input string name,
                             input bit poke_while_busy);
        int cycles;
        logic [127:0] result;
        @(negedge clk);
        while (!ready) @(negedge clk);
        key = k; block_in = p; start = 1'b1;
        @(negedge clk);                                 // accepting edge passed
        start = 1'b0;
        key = rand128(); block_in = rand128();          // check 4
        cycles = 0;
        while (!done) begin
            if (ready) $fatal(1, "[%s] ready high while busy (cycle %0d)", name, cycles);
            if (poke_while_busy && cycles == 3) begin   // check 5
                start = 1'b1;
                @(negedge clk); cycles++;
                start = 1'b0;
                continue;
            end
            @(negedge clk); cycles++;
            if (cycles > 50) $fatal(1, "[%s] timeout waiting for done", name);
        end
        if (cycles != LATENCY)
            $fatal(1, "[%s] latency %0d, expected %0d", name, cycles, LATENCY);
        result = block_out;
        if (result !== e)
            $fatal(1, "[%s] MISMATCH\n  key = %032h\n  pt  = %032h\n  got = %032h\n  exp = %032h",
                   name, k, p, result, e);
        @(negedge clk);
        if (done)              $fatal(1, "[%s] done longer than 1 cycle", name);
        if (!ready)            $fatal(1, "[%s] not ready after done", name);
        repeat (3) @(negedge clk);
        if (block_out !== e)   $fatal(1, "[%s] block_out not held after done", name);  // check 6
    endtask

    int i;
    time t0, t1;

    initial begin
        // ---- known-answer vectors -----------------------------------------
        add_vec(128'h000102030405060708090a0b0c0d0e0f, 128'h00112233445566778899aabbccddeeff,
                128'h69c4e0d86a7b0430d8cdb78070b4c55a, "FIPS-197 C.1");
        add_vec(128'h2b7e151628aed2a6abf7158809cf4f3c, 128'h3243f6a8885a308d313198a2e0370734,
                128'h3925841d02dc09fbdc118597196a0b32, "FIPS-197 App. B");
        add_vec(128'h00000000000000000000000000000000, 128'h00000000000000000000000000000000,
                128'h66e94bd4ef8a2c3b884cfa59ca342b2e, "all-zero");
        add_vec(128'h2b7e151628aed2a6abf7158809cf4f3c, 128'h6bc1bee22e409f96e93d7e117393172a,
                128'h3ad77bb40d7a3660a89ecaf32466ef97, "SP800-38A blk1");
        add_vec(128'h2b7e151628aed2a6abf7158809cf4f3c, 128'hae2d8a571e03ac9c9eb76fac45af8e51,
                128'hf5d3d58503b9699de785895a96fdbaaf, "SP800-38A blk2");
        add_vec(128'h2b7e151628aed2a6abf7158809cf4f3c, 128'h30c81c46a35ce411e5fbc1191a0a52ef,
                128'h43b1cd7f598ece23881b00e3ed030688, "SP800-38A blk3");
        add_vec(128'h2b7e151628aed2a6abf7158809cf4f3c, 128'hf69f2445df4f9b17ad2b417be66c3710,
                128'h7b0c785e27e8ad3f8223207104725dd4, "SP800-38A blk4");

        // ---- random vectors (key, plaintext, ciphertext) from .NET AES -------
        add_vec(128'h23ca026029a4085f19093cc222469171, 128'h8540152085da5668d1fc60a8cd4df140, 128'h78ba7aa23198243a7018d75532512f13);
        add_vec(128'hf1b291d41c4fe889c680a7e01ec025f4, 128'h574522d6d9aec4ccf70756a39e4297e9, 128'h0f3bd24580ea307221e0485a1158c520);
        add_vec(128'h52a9586d8a8a7d6bb286ca344cf91172, 128'h244152019a5547ada524f29728948989, 128'h65df4facc00c809534d7387684fa839d);
        add_vec(128'h34f90e80ba1df5b4156c4e42812e5f3a, 128'hc21d71848fe4872982cd8c96b23c75d5, 128'h87821dcde8d545d0a05d2064820b0127);
        add_vec(128'h6bbc726809bc0cd9f9707d4f76dfec01, 128'h53e213922ce5c19dffc98124cf1b9433, 128'h83eec029b1f133953e6782f6a05f335f);
        add_vec(128'hbcb7b4042323234fa0f2ffe7b0167198, 128'hbc7fec25e020102eaa2a60175ee5288b, 128'h3086897c07f6ca1cec1b5c7895f7e7fd);
        add_vec(128'h203f19263e7f645607f66411f721e7f9, 128'h95530d6073f4bedcea030583ba786d57, 128'h84bacc006383b56958ae757695bba540);
        add_vec(128'h5be4a73d5865c01c38b62eb4a6501d45, 128'h366142f0b66636f7f3272f388de6036c, 128'h9aaa10f5ea3a041901a0e8956f83a5f6);
        add_vec(128'h1373159517259e73bf360fde0c56d088, 128'h3c8397c8997b77b224adf83a1f06765e, 128'h80337e018880d53542229dd366a2e457);
        add_vec(128'hf8e00b24377c028c4b167a295f51f926, 128'h336ea466923823f48abb810dccfb93a7, 128'h20fcc1057fffbf789cd9bbba3fb39c9f);
        add_vec(128'hda6c4b48bed70495dd4eb7bd3fdd271b, 128'hdf9ae3769e358c84fb86ebd5fc1ed128, 128'h50e5117216ee509ef1eebde15a91d6f8);
        add_vec(128'hc3bbd26128f3cc4916c5209178b7ae8a, 128'hd62ab67cda897ed0539d91e41b0a879f, 128'h2fb13b89b63eb6a34ae4ec542ac0f7c6);
        add_vec(128'he1123b82d1cfc86ee1fc00780cccff76, 128'hf0b7d82b5f93b025ce4cce5296181aff, 128'h7d0592a81a5d873f04a60bb746971853);
        add_vec(128'h3016f0ab5c003b5f980de2cec11bb903, 128'he7a28a0d767279ed7e262e66a17ab0d1, 128'h56035d9c596927ce61637f050eb6f532);
        add_vec(128'h9747df435907172493a3d7adc43c618d, 128'hd46a14657119f06f1f90c3d05b62337a, 128'h717c085cb6a9a2eac4fb6103755d5a65);
        add_vec(128'hdf8c1811521f21d0a3302bbbd7b1e3ab, 128'he1f99b9fecde20aca1cdbeee0e988b28, 128'h61751dc71de27b90fa7a62beae5daa32);
        add_vec(128'ha1da7b27ca35b43a52e64ef12b2c188e, 128'h6d6bfb1a61326cf9b45e689bfdfa38bd, 128'hcf21b7cbca09dd629e0533b1ba6d71e6);
        add_vec(128'hf75d144e19213f0d4fc0efd6d14807c3, 128'h6707481366ad2c8e2df0bdc5fbdc4167, 128'hb03da2af0f4933f441a119835aa87be4);
        add_vec(128'h64de50650ba6c6a6ace403b06531828d, 128'h71fc31b1ca6e008b5d015d7c1a0dd76a, 128'h2b2e7c1a5304552bed4fbe766dec160d);
        add_vec(128'hb41e56e3ea3cc064dc8a7f490a3ba16d, 128'h1180c2cda10bfae90b0f9669eeec878a, 128'h31a1c4361f87add8a5c493f3cc78b8ea);
        add_vec(128'h809a65559abc0d62b2810395d4322170, 128'hdb0217b3b8554d0dc9060222849bd52f, 128'h248ec84daa124baa546f5d3449d47362);
        add_vec(128'ha1dad19127213083abd3b00bd30aad06, 128'hd0e33a800cb0fc8715eba370c53d8d60, 128'hf2ce314fbb086dd9e697b683584ac638);
        add_vec(128'h087516eeebdfcaee56219162b42e1767, 128'h9bd5d35e6e2ed578c715f25f3062eaa2, 128'h5ef98d20e9ec9cea1bb08a61e6fff65b);
        add_vec(128'h0a10b325c49af45eb99797e12f93eac3, 128'h5bfb11da47ca55e9fcbb1d6070ef66b1, 128'h399f2495d308c278499ad55067a6ca97);
        add_vec(128'ha0ddac1e3e566ee708bd6ab1e11ab7ac, 128'h0ee8d2ee64653cb46a52b739fc4448fb, 128'h1d025e1c8eacc0c769bfc605fdc3cddf);
        add_vec(128'h44ca90d60822dccf9732a55ce6125b62, 128'h8db1972c477ca02077578ee49c738918, 128'h4f7aca0c6a859d80122043740c395b40);
        add_vec(128'h3aeaae917d7ca6f99369bab40bc4a6f4, 128'h94fce4229de1eaefca14c95f8e16d7be, 128'he182a5e7723a552bcc2a1464b619785a);
        add_vec(128'h33baf2b0b5f66c0c466eeebf8a109289, 128'h18e5fe53a23a25e933a6bfaa56657f97, 128'h684fc6f990cf8c5e5e4e26c0da35dda1);
        add_vec(128'hd05fa785f6355652ac2cd581a8df0532, 128'haa156e56781fcd4fa874b84b8503c9f8, 128'h86fc9a6137526edc0464734d048d125a);
        add_vec(128'h9fa1a19ef723ba6ea57235d1528cac46, 128'h7c58b23bd292856c7c14f6b6cc3c1a8b, 128'hd255a5f8e483b372840100b342e60596);
        add_vec(128'h2f34b83dce7318b81ad1e85ed6db35a7, 128'hb2748c6970eb222e8beedf1aaf0810b1, 128'h5be3ff0d890168edbef32b723ff6b024);
        add_vec(128'h32a6b071c41f92564cc2e8a6e7c31578, 128'hf945d3567976b7b656487a94ff87d8ed, 128'h8bcc07e58f3a6472b2d8c6678ce5e7e7);

        // ---- reset -----------------------------------------------------------
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        if (!ready) $fatal(1, "not ready after reset");
        if (done)   $fatal(1, "done high after reset");

        // ---- checks 1-6 -------------------------------------------------------
        for (i = 0; i < vk.size(); i++)
            run_block(vk[i], vp[i], ve[i], vname[i], (i % 2) == 1);
        $display("PASS: %0d vectors (%0d known-answer, %0d random), latency = %0d cycles",
                 vk.size(), N_KAT, vk.size() - N_KAT, LATENCY);

        // ---- check 7: reset in the middle of a block -------------------------
        @(negedge clk);
        key = vk[0]; block_in = vp[0]; start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        repeat (4) @(negedge clk);
        rst = 1'b1;
        @(negedge clk);
        rst = 1'b0;
        repeat (LATENCY + 5) begin
            @(negedge clk);
            if (done) $fatal(1, "done after reset abort");
        end
        run_block(vk[0], vp[0], ve[0], "after reset abort", 1'b0);
        $display("PASS: reset in the middle of a block");

        // ---- check 8: back-to-back throughput --------------------------------
        // Hold start high; load the next block in the cycle after each done.
        @(negedge clk);
        i = 0;
        key = vk[0]; block_in = vp[0]; start = 1'b1;
        t0 = $time;
        while (i < 8) begin
            @(negedge clk);
            if (done) begin
                if (block_out !== ve[i]) $fatal(1, "back-to-back block %0d mismatch", i);
                i++;
                key = vk[i]; block_in = vp[i];
            end
        end
        start = 1'b0;               // drop start before the 9th block is accepted
        t1 = $time;
        // first done after LATENCY+1 cycles, then one every PERIOD cycles
        if ((t1 - t0) != 10 * (LATENCY + 1 + 7 * PERIOD))
            $fatal(1, "back-to-back: %0t for 8 blocks, expected %0d ns",
                   t1 - t0, 10 * (LATENCY + 1 + 7 * PERIOD));
        $display("PASS: back-to-back, one block every %0d cycles", PERIOD);

        // ---- check 9 ----------------------------------------------------------
        repeat (2 * PERIOD) @(negedge clk);
        if (n_accepted != n_done)
            $fatal(1, "accepted starts (%0d) != done pulses (%0d)", n_accepted, n_done);
        $display("PASS: %0d starts accepted, %0d done pulses", n_accepted, n_done);

        $display("TEST PASSED");
        $finish;
    end

    initial begin
        #1ms;
        $fatal(1, "global timeout");
    end

endmodule
