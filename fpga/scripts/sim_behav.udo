##########################################################################
# Behavioral CVA6 QuestaSim simulation
# this QuestaSim TCL script handles the actual simulation execution
# it sets the simulation length, and saves the simulation results
# to the appropiate results/ folder
##########################################################################

set SIM_LENGTH 185
set SIM_UNITS "ms"
set TOPLEVEL_PATH "/tb_cva6_zybo_z7_20/DUT/i_ariane"

do waveforms.udo

run $SIM_LENGTH$SIM_UNITS
run @$SIM_LENGTH$SIM_UNITS

# extra results saved if we're running make cva6_riscmakers
if {[info exists ::env(PATH_RESULTS_BEHAV)]} {
    set PERFORMANCE_COUNTERS_FILE "$::env(PATH_RESULTS_BEHAV)/performance_counters.txt"
    set WLF_SIM_NAME "vsim"

    # -p incase the directory exists already
    exec mkdir -p "$::env(PATH_RESULTS_BEHAV)"
    dataset save sim "$::env(PATH_RESULTS_BEHAV)/$WLF_SIM_NAME.wlf"

    file copy -force uart "$::env(PATH_RESULTS_BEHAV)"

    # Instruction cache misses
    set num_icache_misses [examine -radix unsigned -time $SIM_LENGTH$SIM_UNITS "${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2819]"]

    # Data cache misses
    set num_dcache_misses [examine -radix unsigned -time $SIM_LENGTH$SIM_UNITS "${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2820]"]

    # Memory instructions
    set num_loads [examine -radix unsigned -time $SIM_LENGTH$SIM_UNITS "${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2823]"]
    set num_stores [examine -radix unsigned -time $SIM_LENGTH$SIM_UNITS "${TOPLEVEL_PATH}/i_perf_counters/perf_counter_q[2824]"]

    # create some data
    set performance_counters_data ""
    append performance_counters_data "Number of Loads: ${num_loads}\n"
    append performance_counters_data "Number of Stores: ${num_stores}\n"
    append performance_counters_data "Number of Instruction Cache Misses: ${num_icache_misses}\n"
    append performance_counters_data "Number of Data Cache Misses: ${num_dcache_misses}"

    # open the performance_counters file for writing
    set performance_counters_id [open $PERFORMANCE_COUNTERS_FILE "w"]

    # omitting '-nonewline' will result in an extra newline at the end of the file
    puts -nonewline $performance_counters_id $performance_counters_data

    # close the file, ensuring the data is written out before you continue
    #  with processing.
    close $performance_counters_id  
}

# batch_mode == 1 if in batch mode
# batch_mode == 0 if in GUI mode
if [batch_mode] {
    puts "\[sim_behav.udo\] batch mode = True"

    # let the user quit if they want to when not in batch mode
    # this gives them a chance to see sim results
    quit -f
}
