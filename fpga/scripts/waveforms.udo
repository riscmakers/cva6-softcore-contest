##########################################################################
# this QuestaSim TCL script handles all the waveforms we want to visualize
# in the wavewindow (signals of interest, registers, etc.)
##########################################################################

onerror {resume}

set TOPLEVEL_PATH "/tb_cva6_zybo_z7_20/DUT/i_ariane"

# batch_mode == 1 if in batch mode
# batch_mode == 0 if in GUI mode
if ![batch_mode] {
    do waveforms_gui.udo
    # questa yells at me when I put this outside of the "if" statement
    # "[QUESTA]: delete wave not supported in batch mode"
    delete wave *
}

# non-grouped signals
add wave -noupdate ${TOPLEVEL_PATH}/clk_i
add wave -noupdate ${TOPLEVEL_PATH}/issue_stage_i/i_issue_read_operands/stall

add wave -noupdate -group dcache ${TOPLEVEL_PATH}/i_cache_subsystem/i_riscmakers_dcache/*

# performance counters
add wave -noupdate -group performance ${TOPLEVEL_PATH}/i_perf_counters/l1_icache_miss_i 
add wave -noupdate -group performance ${TOPLEVEL_PATH}/i_perf_counters/l1_dcache_miss_i 
add wave -noupdate -group performance -group totals -label icache_miss -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2819]
add wave -noupdate -group performance -group totals -label dcache_miss -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2820]
add wave -noupdate -group performance -group totals -label loads -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2823]
add wave -noupdate -group performance -group totals -label stores -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2824]