# Get current datetime in YYYYMMDDhhmmss format
set now [clock format [clock seconds] -format "%Y%m%d%H%M%S"]

# Output to a Verilog header file
set out_file "hdl/datetime.svh"
set fp [open $out_file "w"]
puts $fp "// Generated build timestamp"
puts $fp "`define BUILD_DATETIME \"$now\""
close $fp
