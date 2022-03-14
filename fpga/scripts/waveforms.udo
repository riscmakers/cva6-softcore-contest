##########################################################################
# this QuestaSim TCL script handles all the waveforms we want to visualize
# in the wavewindow (signals of interest, registers, etc.)
##########################################################################

set TOPLEVEL_PATH "/tb_cva6_zybo_z7_20/DUT/i_ariane"

# batch_mode == 1 if in batch mode
# batch_mode == 0 if in GUI mode
if ![batch_mode] {
    do waveforms_gui.udo
    # questa yells at me when I put this outside of the "if" statement
    # "[QUESTA]: delete wave not supported in batch mode"
    delete wave *
}

# hint: expand signal using this syntax:
# add wave -expand <signal> 

# non-grouped signals
add wave -noupdate ${TOPLEVEL_PATH}/clk_i
add wave -noupdate ${TOPLEVEL_PATH}/issue_stage_i/i_issue_read_operands/stall
add wave -noupdate ${TOPLEVEL_PATH}/resolved_branch

# instructions
add wave -noupdate -group instruction -binary ${TOPLEVEL_PATH}/i_frontend/i_instr_queue/instr_i
add wave -noupdate -group instruction -hex ${TOPLEVEL_PATH}/i_frontend/i_instr_queue/addr_i

# caches
add wave -noupdate -group cache -group data -label evict_cache_instr ${TOPLEVEL_PATH}/i_cache_subsystem/i_wt_icache/update_lfsr 
add wave -noupdate -group cache -group data -label evict_cache_data ${TOPLEVEL_PATH}/i_cache_subsystem/i_wt_dcache/i_wt_dcache_missunit/update_lfsr

# addresses 
set areq_i [find signals /*/areq_i -recursive]
set areq_o [find signals /*/areq_o -recursive]
set dreq_i [find signals /*/dreq_i -recursive]
set dreq_o [find signals /*/dreq_o -recursive]
set req_ports_i [find signals /*/req_ports_i -recursive]
set req_ports_o [find signals /*/req_ports_o -recursive]

add wave -noupdate -group cache -group instr $areq_i
add wave -noupdate -group cache -group instr $areq_o
add wave -noupdate -group cache -group instr $dreq_i
add wave -noupdate -group cache -group instr $dreq_o
add wave -noupdate -group cache -group data $req_ports_i
add wave -noupdate -group cache -group data $req_ports_o

add wave -noupdate -group cache -group data ${TOPLEVEL_PATH}/ex_stage_i/lsu_i/i_store_unit/i_amo_buffer/amo_resp_i
add wave -noupdate -group cache -group data ${TOPLEVEL_PATH}/ex_stage_i/lsu_i/i_store_unit/i_amo_buffer/amo_req_o
add wave -noupdate -group cache -group data ${TOPLEVEL_PATH}/i_cache_subsystem/i_wt_icache/mem_data_o
add wave -noupdate -group cache -group instr ${TOPLEVEL_PATH}/i_cache_subsystem/i_wt_dcache/i_wt_dcache_missunit/mem_data_o

# performance counters
add wave -noupdate -group performance ${TOPLEVEL_PATH}/i_perf_counters/l1_icache_miss_i 
add wave -noupdate -group performance ${TOPLEVEL_PATH}/i_perf_counters/l1_dcache_miss_i 
add wave -noupdate -group performance ${TOPLEVEL_PATH}/i_perf_counters/sb_full_i 
add wave -noupdate -group performance ${TOPLEVEL_PATH}/i_perf_counters/if_empty_i 
add wave -noupdate -group performance ${TOPLEVEL_PATH}/i_perf_counters/ex_i 
add wave -noupdate -group performance ${TOPLEVEL_PATH}/i_perf_counters/eret_i 
add wave -noupdate -group performance ${TOPLEVEL_PATH}/i_perf_counters/resolved_branch_i 

add wave -noupdate -group performance -group totals -label icache_miss -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2819]
add wave -noupdate -group performance -group totals -label dcache_miss -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2820]
add wave -noupdate -group performance -group totals -label loads -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2823]
add wave -noupdate -group performance -group totals -label stores -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2824]
add wave -noupdate -group performance -group totals -label exceptions -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2825]
add wave -noupdate -group performance -group totals -label exception_returns -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2826]
add wave -noupdate -group performance -group totals -label jump_branches -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2827]
add wave -noupdate -group performance -group totals -label calls -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2828]
add wave -noupdate -group performance -group totals -label returns -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2829]
add wave -noupdate -group performance -group totals -label branch_mispredicts -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2830]
add wave -noupdate -group performance -group totals -label scoreboard_full -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2831]
add wave -noupdate -group performance -group totals -label instr_queue_empty -unsigned ${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2832]

# instr trace (add conditional, to see if these signals were included to debug simulation)
# add wave -noupdate -group instr_tracer ${TOPLEVEL_PATH}/instr_tracer_i/tracer_if/*