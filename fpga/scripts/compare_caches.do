onerror {resume}
quietly set dataset_list [list riscmakers base]
if {[catch {datasetcheck $dataset_list}]} {abort}
quietly WaveActivateNextPane {} 0
add wave -noupdate -label clk riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/clk_i
add wave -noupdate -expand -group miss riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/miss_o
add wave -noupdate -expand -group miss base:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_perf_counters/l1_dcache_miss_i
add wave -noupdate -group stall riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/issue_stage_i/i_issue_read_operands/stall
add wave -noupdate -group stall base:/tb_cva6_zybo_z7_20/DUT/i_ariane/issue_stage_i/i_issue_read_operands/stall
add wave -noupdate -expand -group mem riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/mem_data_req_o
add wave -noupdate -expand -group mem riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/mem_data_ack_i
add wave -noupdate -expand -group mem -expand riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/mem_data_o
add wave -noupdate -expand -group mem riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/mem_rtrn_vld_i
add wave -noupdate -expand -group mem riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/mem_rtrn_i
add wave -noupdate -expand -group mem base:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_wt_dcache/mem_data_o
add wave -noupdate -expand -group mem base:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_wt_dcache/mem_data_req_o
add wave -noupdate -expand -group mem base:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_wt_dcache/mem_rtrn_i
add wave -noupdate -expand -group mem base:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_wt_dcache/mem_rtrn_vld_i
add wave -noupdate -expand -group mem base:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_wt_dcache/mem_data_ack_i
add wave -noupdate -expand -group requests_i -label base:load -childformat {{address_index -radix hexadecimal} {address_tag -radix hexadecimal}} -expand -subitemconfig {{/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_wt_dcache/req_ports_i[1].address_index} {-radix hexadecimal} {/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_wt_dcache/req_ports_i[1].address_tag} {-radix hexadecimal}} {base:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_wt_dcache/req_ports_i[1]}
add wave -noupdate -expand -group requests_i -label riscmakers:load -childformat {{address_index -radix hexadecimal} {address_tag -radix hexadecimal}} -expand -subitemconfig {{/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/req_ports_i[1].address_index} {-radix hexadecimal} {/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/req_ports_i[1].address_tag} {-radix hexadecimal}} {riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/req_ports_i[1]}
add wave -noupdate -expand -group requests_i -label base:store -childformat {{address_index -radix hexadecimal} {address_tag -radix hexadecimal}} -expand -subitemconfig {{/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_wt_dcache/req_ports_i[2].address_index} {-radix hexadecimal} {/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_wt_dcache/req_ports_i[2].address_tag} {-radix hexadecimal}} {base:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_wt_dcache/req_ports_i[2]}
add wave -noupdate -expand -group requests_i -label riscmakers:store -childformat {{address_index -radix hexadecimal} {address_tag -radix hexadecimal}} -expand -subitemconfig {{/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/req_ports_i[2].address_index} {-radix hexadecimal} {/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/req_ports_i[2].address_tag} {-radix hexadecimal}} {riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/req_ports_i[2]}
add wave -noupdate -group requests_o -label load_req_out {riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/req_ports_o[1]}
add wave -noupdate -group requests_o -label store_req_out {riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/req_ports_o[2]}
add wave -noupdate -group requests_o -label base:store_req_out {base:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_wt_dcache/req_ports_o[2]}
add wave -noupdate -group requests_o -label base:load_req_out {base:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_wt_dcache/req_ports_o[1]}
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/current_state_q
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/next_state_d
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/miss_load
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/miss_store
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/current_request
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/is_cache_servicing_request
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/is_cache_ready_for_request
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/tag_store_compare_done
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/tag_store_compare_done_neg_q
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/tag_store_compare_done_pos_q
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/tag_compare_hit
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/writeback_flag_d
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/writeback_flag_q
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/writeback_flag_en
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/req_port_select
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/req_port_i_d
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/req_port_i_q
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/tag_store
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/data_store
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/req_port_address
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/dcache_address
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/req_port_block_index
add wave -noupdate -group internal_riscmakers riscmakers:/tb_cva6_zybo_z7_20/DUT/i_ariane/i_cache_subsystem/i_riscmakers_dcache/req_port_block_offset
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {45964888 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 257
configure wave -valuecolwidth 215
configure wave -justifyvalue left
configure wave -signalnamewidth 1
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ms
update
WaveRestoreZoom {45904669 ps} {46407264 ps}
