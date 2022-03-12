##########################################################################
# this QuestaSim TCL script handles how the waveforms are formatted
# and how the signals are displayed (radix, full zoom, etc)
##########################################################################

view -undock wave

# only display leaf names and not hierarchy (set value to 0 for full-path)
config wave -signalnamewidth 1

# time units for wave window
configure wave -timelineunits ms

# time is in ms
wave zoom range 0ms 60ms

# easily view performance counter values at end of simulation
wave cursor configure -time 60ms