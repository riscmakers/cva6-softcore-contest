##########################################################################
# Post-implementation CVA6 QuestaSim simulation
# this QuestaSim TCL script handles the actual simulation execution
# it sets the simulation length, and exports the power results
#
# NOTE: to get the parent directory of the cva6 repo:
#       relative path is ../../../../../../ for post-impl sim
#       relative path is ../../../../../    for behav sim 
#       to get to work-sim:
#       relative path is ../../../../../ 
##########################################################################

set SIM_LENGTH 67
set SIM_UNITS "ms"

power add -in -inout -internal -out -r /tb_cva6_zybo_z7_20/DUT/*

run $SIM_LENGTH$SIM_UNITS
run @$SIM_LENGTH$SIM_UNITS

power report -all -bsaif ../../../../../work-sim/routed.saif

# batch_mode == 1 if in batch mode
# batch_mode == 0 if in GUI mode
if [batch_mode] {
    quit -f
}
