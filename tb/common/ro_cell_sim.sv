// ============================================================================
// ro_cell_sim : behavioral ring-oscillator model (simulation only).
//
// Same ports as rtl/rover/ro_cell.v. Used by ro_puf / ro_trng when SIM_RO = 1.
// Settings come from puf_sim_pkg (chip, run, variation, bias, noise), read
// at every enable, so a testbench can switch chip or power-up between runs.
//   period = NOM_PS * (1 + process_variation(chip, IDX) + bias(IDX))
//   each enable: frequency offset ~ N(0, env_ppm); each half period adds
//   jitter ~ N(0, jit_ppm)
// Stopped output = 1, like the NAND-enable ring in ro_cell.v.
// ============================================================================
`timescale 1ns/1ps
module ro_cell_sim #(
    parameter int  IDX    = 0,
    parameter real NOM_PS = 4000.0       // 250 MHz nominal
) (
    input  logic en,
    output logic ro_out
);
    import puf_sim_pkg::*;

    int unsigned st;
    int          seeded_run  = -1;
    int          seeded_chip = -1;

    initial ro_out = 1'b1;

    always @(posedge en) begin
        real period, env, half;
        if (seeded_run != run || seeded_chip != chip) begin
            st          = noise_seed(IDX);
            seeded_run  = run;
            seeded_chip = chip;
        end
        period = ro_period_ps(IDX, NOM_PS);
        env    = gauss(st) * env_ppm / 1.0e6;
        while (en) begin
            half = period / 2.0 * (1.0 + env + gauss(st) * jit_ppm / 1.0e6);
            #(half / 1000.0);
            if (en) ro_out = ~ro_out;
        end
        ro_out = 1'b1;
    end
endmodule
