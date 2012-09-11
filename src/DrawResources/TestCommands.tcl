# Copyright (c) 2012 OPEN CASCADE SAS
#
# The content of this file is subject to the Open CASCADE Technology Public
# License Version 6.5 (the "License"). You may not use the content of this file
# except in compliance with the License. Please obtain a copy of the License
# at http://www.opencascade.org and read it completely before using this file.
#
# The Initial Developer of the Original Code is Open CASCADE S.A.S., having its
# main offices at: 1, place des Freres Montgolfier, 78280 Guyancourt, France.
#
# The Original Code and all software distributed under the License is
# distributed on an "AS IS" basis, without warranty of any kind, and the
# Initial Developer hereby disclaims all such warranties, including without
# limitation, any warranties of merchantability, fitness for a particular
# purpose or non-infringement. Please see the License for the specific terms
# and conditions governing the rights and limitations under the License.

############################################################################
# This file defines scripts for execution of OCCT tests.
# It should be loaded automatically when DRAW is started, and provides
# three top-level commands: 'test', 'testgrid', and 'testdiff'.
# See OCCT Tests User Guide for description of the test system.
#
# Note: procedures with names starting with underscore are for internal use 
# inside the test system.
############################################################################

# Default verbose level for command _run_test
set _tests_verbose 0

# regexp for parsing test case results in summary log
set _test_case_regexp {^CASE\s+([\w.-]+)\s+([\w.-]+)\s+([\w.-]+)\s*:\s*([\w]+)(.*)}

# Basic command to run indicated test case in DRAW
help test {Run specified test case
    Use: test group grid casename [verbose_level]
    Verbose level is 0 by default; can be set to 1 or 2}
proc test {group grid casename {verbose {}}} {
    global _tests_verbose
    if { $verbose != "" } {
	set _tests_verbose $verbose
    }
 
    # get test case paths (will raise error if input is invalid)
    _get_test $group $grid $casename dir gridname casefile

    # run test
    uplevel _run_test $dir $group $gridname $casefile

    # check log
    _check_log $dir $group $gridname $casename [dlog get]

    return
}

# Basic command to run indicated test case in DRAW
help testgrid {Run all tests, or specified group, or one grid
    Use: testgrid logdir [group [grid]] [options...]
    Log directory should be empty (or non-existing)
    Allowed options are:
    -parallel N: run in parallel mode with up to N processes (default 0)
    -refresh N: save summary logs every N seconds (default 60, minimal 1, 0 to disable)
    -overwrite: force writing logs in existing non-empty directory
    -xml filename: write XML report for Jenkins (in JUnit-like format)
}
proc testgrid {logdir args} {
    global env tcl_platform _tests_verbose

    ######################################################
    # check arguments
    ######################################################

    # check that environment variable defining paths to test scripts is defined
    if { ! [info exists env(CSF_TestScriptsPath)] || 
         [llength $env(CSF_TestScriptsPath)] <= 0 } {
        error "Error: Environment variable CSF_TestScriptsPath is not defined"
    }

    # treat options
    set parallel 0
    set refresh 60
    set overwrite 0
    set xmlfile ""
    for {set narg 0} {$narg < [llength $args]} {incr narg} {
	set arg [lindex $args $narg]

	# parallel execution
	if { $arg == "-parallel" } {
	    incr narg
	    if { $narg < [llength $args] } { 
		set parallel [expr [lindex $args $narg]]
	    } else {
		set paralell 2
	    }
	    continue
	}

	# refresh logs time
	if { $arg == "-refresh" } {
	    incr narg
	    if { $narg < [llength $args] } { 
		set refresh [expr [lindex $args $narg]]
	    } else {
		set refresh 10
	    }
	    continue
	}

	# allow overwrite logs 
	if { $arg == "-overwrite" } {
	    set overwrite 1
	    continue
	}

	# refresh logs time
	if { $arg == "-xml" } {
	    incr narg
	    if { $narg < [llength $args] } { 
		set xmlfile [lindex $args $narg]
	    }
	    if { $xmlfile == "" } {
		set xmlfile TESTS-summary.xml
	    }
	    continue
	}

	# unsupported option
	if { [regexp {^-} $arg] } {
	    error "Error: unsupported option \"$arg\""
	}

	# treat arguments not recognized as options as group and grid names
	if { ! [info exists groupname] } {
	    set groupname $arg
	} elseif { ! [info exists gridname] } {
	    set gridname $arg
	} else {
	    error "Error: cannot interpret argument $narg ($arg): both group and grid names are already defined by previous args!"
	}
    }

    # check that target log directory is empty or does not exist
    set logdir [file normalize [string trim $logdir]]
    if { $logdir == "" } {
	# if specified logdir is empty string, generate unique name like "results_2010-12-31T23:59:59"
	set logdir "results_[clock format [clock seconds] -format {%Y-%m-%dT%H%M}]"
	set logdir [file normalize $logdir]
    }
    if { [file isdirectory $logdir] && ! $overwrite && ! [catch {glob -directory $logdir *}] } {
	error "Error: Specified log directory \"$logdir\" is not empty; please clean it before running tests"
    } 
    if { [catch {file mkdir $logdir}] || ! [file writable $logdir] } {
	error "Error: Cannot create directory \"$logdir\", or it is not writable"
    }

    ######################################################
    # prepare list of tests to be performed
    ######################################################

    # list of tests, each defined by a list of:
    # test scripts directory
    # group (subfolder) name
    # grid (subfolder) name
    # test case name
    # path to test case file
    set tests_list {}

    # iterate by all script paths
    foreach dir [_split_path $env(CSF_TestScriptsPath)] {
	# protection against empty paths
	set dir [string trim $dir]
	if { $dir == "" } { continue }

	if { $_tests_verbose > 0 } { _log_and_puts log "Examining tests directory $dir" }

        # check that directory exists
        if { ! [file isdirectory $dir] } {
            _log_and_puts log "Warning: directory $dir listed in CSF_TestScriptsPath does not exist, skipped"
	    continue
        }

        # if test group is specified, check that directory with given name exists in this dir
        # if not, continue to the next test dir
        if { [info exists groupname] && $groupname != "" } {
	    if { [file isdirectory $dir/$groupname] } { 
		set groups $groupname
	    } else {
		continue 
	    }
	} else {
	    # else search all directories in the current dir
	    if [catch {glob -directory $dir -tail -types d *} groups] { continue }
	}

	# iterate by groups
	if { $_tests_verbose > 0 } { _log_and_puts log "Groups to be executed: $groups" }
	foreach group [lsort -dictionary $groups] {
	    if { $_tests_verbose > 0 } { _log_and_puts log "Examining group directory $group" }

	    # file grids.list must exist: it defines sequence of grids in the group
            if { ! [file exists $dir/$group/grids.list] } {
		_log_and_puts log "Warning: directory $dir/$group does not contain file grids.list, skipped"
		continue
	    }

	    # read grids.list file and make a list of grids to be executed
	    set gridlist {}
	    set fd [open $dir/$group/grids.list]
	    set nline 0
	    while { [gets $fd line] >= 0 } {
		incr nline

		# skip comments and empty lines
		if { [regexp "\[ \t\]*\#.*" $line] } { continue }
		if { [string trim $line] == "" } { continue }

		# get grid id and name
		if { ! [regexp "^\(\[0-9\]+\)\[ \t\]*\(\[A-Za-z0-9_.-\]+\)\$" $line res gridid grid] } {
		    _log_and_puts log "Warning: cannot recognize line $nline in file $dir/$group/grids.list as \"gridid gridname\"; ignored"
		    continue
		}
		
		# if specific grid is requested, check that it is present; otherwise make complete list
		if { ! [info exists gridname] || $gridname == "" || $gridname == $gridid || $gridname == $grid } {
		    lappend gridlist $grid
		}
	    }
	    close $fd
	    
	    # iterate by all grids
	    foreach grid $gridlist {

		# check if this grid is aliased to another one
		set griddir $dir/$group/$grid
		if { [file exists $griddir/cases.list] } {
		    set fd [open $griddir/cases.list]
		    if { [gets $fd line] >= 0 } {
			set griddir [file normalize $dir/$group/$grid/[string trim $line]]
		    }
		    close $fd
		}

		# check if grid directory actually exists
		if { ! [file isdirectory $griddir] } { 
		    _log_and_puts log "Error: tests directory for grid $grid ($griddir) is missing; skipped"
		    continue 
		}

		# create directory for logging test results
		if { $logdir != "" } { file mkdir $logdir/$group/$grid }

		# iterate by all tests in the grid directory
		if { [catch {glob -directory $griddir -type f *} testfiles] } { continue }
		foreach casefile [lsort -dictionary $testfiles] {
		    # filter out begin and end files
		    set casename [file tail $casefile]
		    if { $casename == "begin" || $casename == "end" } { continue }

		    lappend tests_list [list $dir $group $grid $casename $casefile]
		}
	    }
	}
    }
    if { [llength $tests_list] < 1 } {
	error "Error: no tests are found, check you input arguments and variable CSF_TestScriptsPath!"
    }

    ######################################################
    # run tests
    ######################################################
    
    # log command arguments and environment
    set log "Command: testgrid $args\nHost: [info hostname]\nStarted on: [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]\n"
    set log "$log\nEnvironment:\n"
    foreach envar [array names env] {
	set log "$log$envar=\"$env($envar)\"\n"
    }
    set log "$log\n"

    set refresh_timer [clock seconds]
    uplevel dchrono _timer reset
    uplevel dchrono _timer start

    # if parallel execution is requested, allocate thread pool
    if { $parallel > 0 } {
	if { ! [info exists tcl_platform(threaded)] || [catch {package require Thread}] } {
	    _log_and_puts log "Warning: Tcl package Thread is not available, running in sequential mode"
	    set parallel 0
	} else {
	    set worker [tpool::create -minworkers $parallel -maxworkers $parallel]
	    # suspend the pool until all jobs are posted, to prevent blocking of the process
	    # of starting / processing jobs by running threads
	    tpool::suspend $worker
	    if { $_tests_verbose > 0 } { _log_and_puts log "Executing tests in (up to) $parallel threads" }
	}
    }

    # start test cases
    foreach test_def $tests_list {
	set dir       [lindex $test_def 0]
	set group     [lindex $test_def 1]
	set grid      [lindex $test_def 2]
	set casename  [lindex $test_def 3]
	set casefile  [lindex $test_def 4]

	# command to set tests for generation of image in results directory
	set imgdir_cmd ""
	if { $logdir != "" } { set imgdir_cmd "set imagedir $logdir/$group/$grid" }

	# prepare command file for running test case in separate instance of DRAW
	set fd_cmd [open $logdir/$group/$grid/${casename}.tcl w]
	puts $fd_cmd "$imgdir_cmd"
	puts $fd_cmd "set test_image $casename"
	puts $fd_cmd "_run_test $dir $group $grid $casefile"
	# use dlog command to obtain complete output of the test when it is absent (i.e. since OCCT 6.6.0)
	if { ! [catch {dlog get}] } {
	    puts $fd_cmd "puts \[dlog get\]"
	} else {
	    # else try to use old-style QA_ variables to get more output...
	    set env(QA_DUMP) 1
	    set env(QA_DUP) 1
	    set env(QA_print_command) 1
	}
	# final 'exit' is needed when running on Linux under VirtualGl
	puts $fd_cmd "exit"
	close $fd_cmd

        # commant to run DRAW with a command file;
        # note that empty string is passed as standard input to avoid possible 
        # hang-ups due to waiting for stdin of the launching process
	set command "exec <<{} DRAWEXE -f $logdir/$group/$grid/${casename}.tcl"

	# alternative method to run without temporary file; disabled as it needs too many backslashes
#	else {
#	    set command "exec <<\"\" DRAWEXE -c $imgdir_cmd\\\; set test_image $casename\\\; \
#		         _run_test $dir $group $grid $casefile\\\; \
#		         puts \\\[dlog get\\\]\\\; exit"
#	}

	# run test case, either in parallel or sequentially
	if { $parallel > 0 } {
	    # parallel execution
	    set job [tpool::post -nowait $worker "catch \"$command\" output; return \$output"]
	    set job_def($job) [list $logdir $dir $group $grid $casename]
	} else {
	    # sequential execution
	    catch {eval $command} output
	    _log_test_case $output $logdir $dir $group $grid $casename log

	    # update summary log with requested period
	    if { $logdir != "" && $refresh > 0 && [expr [clock seconds] - $refresh_timer > $refresh] } {
		# update and dump summary
		_log_summarize $logdir $log
		set refresh_timer [clock seconds]
	    }
	}
    }

    # get results of started threads
    if { $parallel > 0 } {
	tpool::resume $worker
	while { [llength [array names job_def]] > 0 } {
	    foreach job [tpool::wait $worker [array names job_def]] {
		eval _log_test_case \[tpool::get $worker $job\] $job_def($job) log
		unset job_def($job)
	    }

	    # update summary log with requested period
	    if { $logdir != "" && $refresh > 0 && [clock seconds] > $refresh_timer + $refresh } {
		_log_summarize $logdir $log
		set refresh_timer [clock seconds]
	    }
	}
	# release thread pool
	tpool::release $worker
    }

    uplevel dchrono _timer stop
    set time [lindex [split [uplevel dchrono _timer show] "\n"] 0]

    ######################################################
    # output summary logs and exit
    ######################################################

    _log_summarize $logdir $log $time
    if { $logdir != "" } {
	puts "Detailed logs are saved in $logdir"
    }
    if { $logdir != "" && $xmlfile != "" } {
	# XML output file is assumed relative to log dir unless it is absolute
	if { [ file pathtype $xmlfile] == "relative" } {
	    set xmlfile [file normalize $logdir/$xmlfile]
	}
	_log_xml_summary $logdir $xmlfile $log 0
	puts "XML summary is saved to $xmlfile"
    }

    return
}

# Procedure to compare results of two runs of test cases
help testdiff {Compare results of two executions of tests (CPU times, ...)
    Use: testdiff dir1 dir2 [options...]
    Where dir1 and dir2 are directories containing logs of two test runs.
    Allowed options are:
    -save filename: save resulting log in specified file
    -subdir name: compare only specified subdirectory (can be nested)
    -status {same|ok|all}: filter cases for comparing by their status:
            same - only cases with same status are compared (default)
            ok   - only cases with OK status in both logs are compared
            all  - results are compared regardless of status
    -verbose level: 
            1 - output only differences 
            2 - output list of logs and directories present in one of dirs only
            3 - (default) output progress messages 
}
proc testdiff {dir1 dir2 args} {
    if { "$dir1" == "$dir2" } {
	error "Input directories are the same"
    }

    ######################################################
    # check arguments
    ######################################################

    # treat options
    set logfile ""
    set basename ""
    set status "same"
    set verbose 3
    for {set narg 0} {$narg < [llength $args]} {incr narg} {
	set arg [lindex $args $narg]

	# log file name
	if { $arg == "-save" } {
	    incr narg
	    if { $narg < [llength $args] } { 
		set logfile [lindex $args $narg]
	    } else {
		error "Error: Option -save must be followed by log file name"
	    } 
	    continue
	}

	# subdirectory to compare
	if { $arg == "-subdir" } {
	    incr narg
	    if { $narg < [llength $args] } { 
		set basename [lindex $args $narg]
	    } else {
		error "Error: Option -subdir must be followed by subdirectory path"
	    }
	    continue
	}

	# status filter
	if { $arg == "-status" } {
	    incr narg
	    if { $narg < [llength $args] } { 
		set status [lindex $args $narg]
            } else { set status "" }
	    if { "$status" != "same" && "$status" != "all" && "$status" != "ok" } {
		error "Error: Option -status must be followed by one of \"same\", \"all\", or \"ok\""
	    }
	    continue
	}

	# verbose level
	if { $arg == "-verbose" } {
	    incr narg
	    if { $narg < [llength $args] } { 
		set verbose [expr [lindex $args $narg]]
	    }
	    continue
	}

#	if { [regexp {^-} $arg] } {
	    error "Error: unsupported option \"$arg\""
#	}
    }

    # run diff procedure (recursive)
    _test_diff $dir1 $dir2 $basename $status $verbose log

    # save result to log file
    if { "$logfile" != "" } {
        _log_save $logfile $log
    }

    return
}

# Internal procedure to find test case indicated by group, grid, and test case names;
# returns:
# - dir: path to the base directory of the tests group
# - gridname: actual name of the grid
# - casefile: path to the test case script 
# if no such test is found, raises error with appropriate message
proc _get_test {group grid casename _dir _gridname _casefile} {
    upvar $_dir dir
    upvar $_gridname gridname
    upvar $_casefile casefile

    global env
 
    # check that environment variable defining paths to test scripts is defined
    if { ! [info exists env(CSF_TestScriptsPath)] || 
         [llength $env(CSF_TestScriptsPath)] <= 0 } {
        error "Error: Environment variable CSF_TestScriptsPath is not defined"
    }

    # iterate by all script paths
    foreach dir [_split_path $env(CSF_TestScriptsPath)] {
	# protection against empty paths
	set dir [string trim $dir]
	if { $dir == "" } { continue }

        # check that directory exists
        if { ! [file isdirectory $dir] } {
            puts "Warning: directory $dir listed in CSF_TestScriptsPath does not exist, skipped"
	    continue
        }

        # check if test group with given name exists in this dir
        # if not, continue to the next test dir
        if { ! [file isdirectory $dir/$group] } { continue }

        # check that grid with given name (possibly alias) exists; stop otherwise
        set gridname $grid
        if { ! [file isdirectory $dir/$group/$gridname] } {
            # check if grid is named by alias rather than by actual name
            if { [file exists $dir/$group/grids.list] } {
                set fd [open $dir/$group/grids.list]
                while { [gets $fd line] >= 0 } {
                    if { [regexp "\[ \t\]*\#.*" $line] } { continue }
                    if { [regexp "^$grid\[ \t\]*\(\[A-Za-z0-9_.-\]+\)\$" $line res gridname] } {
                        break
                    }
                }
                close $fd
	    }
	}
        if { ! [file isdirectory $dir/$group/$gridname] } { continue }

        # get actual file name of the script; stop if it cannot be found
        set casefile $dir/$group/$gridname/$casename
        if { ! [file exists $casefile] } {
            # check if this grid is aliased to another one
            if { [file exists $dir/$group/$gridname/cases.list] } {
                set fd [open $dir/$group/$gridname/cases.list]
                if { [gets $fd line] >= 0 } {
                    set casefile [file normalize $dir/$group/$gridname/[string trim $line]/$casename]
                }
		close $fd
	    }
        }
        if { [file exists $casefile] } { 
            # normal return
            return 
        }
    }

    # coming here means specified test is not found; report error
    error [join [list "Error: test case $group / $grid / $casename is not found in paths listed in variable" \
		     "CSF_TestScriptsPath (current value is \"$env(CSF_TestScriptsPath)\")"] "\n"]
}

# Internal procedure to run test case indicated by base directory, 
# grid and grid names, and test case file path.
# The log can be obtained by command "dlog get".
proc _run_test {scriptsdir group gridname casefile} {
    global env

    # start timer
    uplevel dchrono _timer reset
    uplevel dchrono _timer start

    # enable commands logging; switch to old-style mode if dlog command is not present
    set dlog_exists 1
    if { [catch {dlog reset}] } {
	set dlog_exists 0
    } else {
	dlog reset
	dlog on
	rename puts puts-saved
	proc puts args { 
	    global _tests_verbose

	    # log only output to stdout and stderr, not to file!
	    if {[llength $args] > 1} {
		set optarg [lindex $args end-1]
		if { $optarg == "stdout" || $optarg == "stderr" || $optarg == "-newline" } {
		    dlog add [lindex $args end]
		}
	    } else {
		dlog add [lindex $args end]
	    }

	    # reproduce original puts
	    if { $_tests_verbose } {
		eval puts-saved $args
	    }
	}
    }

    # evaluate test case 
    if [catch {
	uplevel set casename [file tail $casefile]
	uplevel set groupname $group
	uplevel set gridname $gridname

        if { [file exists $scriptsdir/$group/begin] } {
	    puts "Executing $scriptsdir/$group/begin..."; flush stdout
	    uplevel source $scriptsdir/$group/begin
	}
	if { [file exists $scriptsdir/$group/$gridname/begin] } {
	    puts "Executing $scriptsdir/$group/$gridname/begin..."; flush stdout
	    uplevel source $scriptsdir/$group/$gridname/begin
	}
	
	puts "Executing $casefile..."; flush stdout
	uplevel source $casefile
	
	if { [file exists $scriptsdir/$group/$gridname/end] } {
	    puts "Executing $scriptsdir/$group/$gridname/end..."; flush stdout
	    uplevel source $scriptsdir/$group/$gridname/end
	}
	if { [file exists $scriptsdir/$group/end] } {
	    puts "Executing $scriptsdir/$group/end..."; flush stdout
	    uplevel source $scriptsdir/$group/end
	}
    } res] {
	puts "Tcl Exception: $res"
    }

    # stop logging
    if { $dlog_exists } {
	rename puts {}
	rename puts-saved puts
	dlog off
    }

    # stop cpulimit killer if armed by the test
    cpulimit

    # add timing info
    uplevel dchrono _timer stop
    set time [uplevel dchrono _timer show]
    if [regexp -nocase {CPU user time:[ \t]*([0-9.e-]+)} $time res cpu] {
	if { $dlog_exists } {
	    dlog add "TOTAL CPU TIME: $cpu sec"
	} else {
	    puts "TOTAL CPU TIME: $cpu sec"
	}
    }
}

# Internal procedure to check log of test execution and decide if it passed or failed
proc _check_log {dir group gridname casename log {_summary {}} {_html_log {}}} {
    global env
    if { $_summary != "" } { upvar $_summary summary }
    if { $_html_log != "" } { upvar $_html_log html_log }
    set summary ""
    set html_log ""

if [catch {

    # load definition of 'bad words' indicating test failure
    # note that rules are loaded in the order of decreasing priority (grid - group - common),
    # thus grid rules will override group ones
    set badwords {}
    foreach rulesfile [list $dir/$group/$gridname/parse.rules $dir/$group/parse.rules $dir/parse.rules] {
	if [catch {set fd [open $rulesfile r]}] { continue }
	while { [gets $fd line] >= 0 } {
	    # skip comments and empty lines
	    if { [regexp "\[ \t\]*\#.*" $line] } { continue }
	    if { [string trim $line] == "" } { continue }
	    # extract regexp
	    if { ! [regexp {^([^/]*)/([^/]*)/(.*)$} $line res status rexp comment] } { 
		puts "Warning: cannot recognize parsing rule \"$line\" in file $rulesfile"
		continue 
	    }
	    set status [string trim $status]
	    if { $comment != "" } { set status "$status ([string trim $comment])" }
	    set rexp [regsub -all {\\b} $rexp {\\y}] ;# convert regexp from Perl to Tcl style
	    lappend badwords [list $status $rexp]
	}
	close $fd
    }
    if { [llength $badwords] <= 0 } { 
	puts "Warning: no definition of error indicators found (check files parse.rules)" 
    }

    # analyse log line-by-line
    set todos {}
    set status ""
    foreach line [split $log "\n"] {
	# check if line defines specific treatment of some messages
	if [regexp -nocase {^[ \t]*TODO ([^:]*):(.*)$} $line res platforms pattern] {
	    if { ! [regexp -nocase {\mAll\M} $platforms] && 
                 ! [regexp -nocase "\\m$env(os_type)\\M" $platforms] } {
		set html_log "$html_log\n$line"
		continue ;# TODO statement is for another platform
	    }

	    # record TODOs that mark unstable cases
	    if { [regexp {[\?]} $platforms] } {
		set todos_unstable([llength $todos]) 1
            }

	    lappend todos [regsub -all {\\b} [string trim $pattern] {\\y}] ;# convert regexp from Perl to Tcl style
	    set html_log "$html_log\n[_html_highlight BAD $line]"
	    continue
	}

	# check for presence of messages indicating test result
	set ismarked 0
	foreach bw $badwords {
	    if { [regexp [lindex $bw 1] $line] } { 
		# check if this is known bad case
		set is_known 0
		for {set i 0} {$i < [llength $todos]} {incr i} {
		    if { [regexp [lindex $todos $i] $line] } {
			set is_known 1
			incr todo_count($i)
			set html_log "$html_log\n[_html_highlight BAD $line]"
			break
		    }
		}

		# if it is not in todo, define status
		if { ! $is_known } {
		    set stat [lindex $bw 0 0]
		    set html_log "$html_log\n[_html_highlight $stat $line]"
		    if { $status == "" && $stat != "OK" && ! [regexp -nocase {^IGNOR} $stat] } {
			set status [lindex $bw 0]
		    }
		}
		set ismarked 1
		break
	    }
	}
	if { ! $ismarked } { 
	    set html_log "$html_log\n$line"
	}
    }

    # check for presence of TEST COMPLETED statement
    if { $status == "" && ! [regexp {TEST COMPLETED} $log] } {
	# check whether absence of TEST COMPLETED is known problem
	set i [lsearch $todos "TEST INCOMPLETE"]
	if { $i >= 0 } {
	    incr todo_count($i)
	} else {
	    set status "FAILED (no final message is found)"
	}
    }

    # check declared bad cases and diagnose possible improvement 
    # (bad case declared but not detected).
    # Note that absence of the problem marked by TODO with question mark
    # (unstable) is not reported as improvement.
    if { $status == "" } {
        for {set i 0} {$i < [llength $todos]} {incr i} {
      	    if { ! [info exists todos_unstable($i)] &&
                 (! [info exists todo_count($i)] || $todo_count($i) <= 0) } {
		set status "IMPROVEMENT (expected problem TODO no. [expr $i + 1] is not detected)"
		break;
	    }
	}
    }

    # report test as known bad if at least one of expected problems is found
    if { $status == "" && [llength [array names todo_count]] > 0 } {
	set status "BAD (known problem)"
    }

    # report normal OK
    if { $status == "" } {set status "OK" }

} res] {
    set status "FAILED ($res)"
}

    # put final message
    _log_and_puts summary "CASE $group $gridname $casename: $status"
    set html_log "[_html_highlight [lindex $status 0] $summary]\n$html_log"
}

# Auxiliary procedure putting message to both cout and log variable (list)
proc _log_and_puts {logvar message} {
    if { $logvar != "" } { 
	upvar $logvar log
	if [info exists log] { 
	    set log "$log$message\n"
	} else {
	    set log "$message\n"
	}
    }
    puts $message
}

# Auxiliary procedure to log result on single test case
proc _log_test_case {output logdir dir group grid casename logvar} {
    upvar $logvar log

    # check result and make HTML log
    _check_log $dir $group $grid $casename $output summary html_log
    set log "$log$summary"

    # save log to file
    if { $logdir != "" } {
	_log_html $logdir/$group/$grid/$casename.html $html_log "Test $group $grid $casename"
	_log_save $logdir/$group/$grid/$casename.log "$output\n$summary" "Test $group $grid $casename"
    }
}

# Auxiliary procedure to save log to file
proc _log_save {file log {title {}}} {
    # create missing directories as needed
    catch {file mkdir [file dirname $file]}

    # try to open a file
    if [catch {set fd [open $file w]} res] {
	error "Error saving log file $file: $res"
    }
    
    # dump log and close
    puts $fd "$title\n"
    puts $fd $log
    close $fd
    return
}

# Auxiliary procedure to save log to file
proc _log_html {file log {title {}}} {
    # create missing directories as needed
    catch {file mkdir [file dirname $file]}

    # try to open a file
    if [catch {set fd [open $file w]} res] {
	error "Error saving log file $file: $res"
    }
    
    # print header
    puts $fd "<html><head><title>$title</title><head><body><h1>$title</h1>"

    # add images if present
    set imgbasename [file rootname [file tail $file]]
    foreach img [lsort [glob -nocomplain -directory [file dirname $file] -tails ${imgbasename}*.gif ${imgbasename}*.png ${imgbasename}*.jpg]] {
	puts $fd "<p><img src=\"$img\"/><p>"
    }

    # print body, then end and close
    puts $fd "<pre>"
    puts $fd $log
    puts $fd "</pre></body></html>"

    close $fd
    return
}

# Auxiliary method to make text with HTML highlighting according to status
proc _html_color {status} {
    # choose a color for the cell according to result
    if { $status == "OK" } { 
	return lightgreen
    } elseif { [regexp -nocase {^FAIL} $status] } { 
	return red
    } elseif { [regexp -nocase {^BAD} $status] } { 
	return yellow
    } elseif { [regexp -nocase {^IMP} $status] } { 
	return orange
    } elseif { [regexp -nocase {^SKIP} $status] } { 
	return gray
    } elseif { [regexp -nocase {^IGNOR} $status] } { 
	return gray
    } else {
	puts "Warning: no color defined for status $status, using red as if FAILED"
	return red
    }
}

# Format text line in HTML to be colored according to the status
proc _html_highlight {status line} {
    return "<table><tr><td bgcolor=\"[_html_color $status]\">$line</td></tr></table>"
}

# Internal procedure to generate HTML page presenting log of the tests
# execution in tabular form, with links to reports on individual cases
proc _log_html_summary {logdir log totals regressions improvements total_time} {
    global _test_case_regexp

     # create missing directories as needed
    catch {file mkdir $logdir}

    # try to open a file and start HTML
    if [catch {set fd [open $logdir/summary.html w]} res] {
	error "Error creating log file: $res"
    }

    # write HRML header, including command to refresh log if still in progress
    puts $fd "<html><head>"
    puts $fd "<title>Tests summary</title>"
    if { $total_time == "" } {
	puts $fd "<meta http-equiv=\"refresh\" content=\"10\">"
    }
    puts $fd "<meta http-equiv=\"pragma\" content=\"NO-CACHE\">"
    puts $fd "</head><body>"

    # put summary
    set legend(OK)          "Test passed OK"
    set legend(FAILED)      "Test failed (regression)"
    set legend(BAD)         "Known problem"
    set legend(IMPROVEMENT) "Possible improvement (expected problem not detected)"
    set legend(SKIPPED)     "Test skipped due to lack of data file"
    puts $fd "<h1>Summary</h1><table>"
    foreach nbstat $totals {
	set status [lindex $nbstat 1]
	if { [info exists legend($status)] } { 
	    set comment $legend($status) 
	} else {
	    set comment "User-defined status"
	}
	puts $fd "<tr><td align=\"right\">[lindex $nbstat 0]</td><td bgcolor=\"[_html_color $status]\">$status</td><td>$comment</td></tr>"
    }
    puts $fd "</table>"

    # time stamp and elapsed time info
    if { $total_time != "" } { 
	puts $fd "<p>Generated on [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] on [info hostname] <p> $total_time" 
    } else {
	puts $fd "<p>NOTE: This is intermediate summary; the tests are still running! This page will refresh automatically until tests are finished."
    }
   
    # print regressions and improvements
    foreach featured [list $regressions $improvements] {
	if { [llength $featured] <= 1 } { continue }
	set status [string trim [lindex $featured 0] { :}]
	puts $fd "<h2>$status</h2>"
	puts $fd "<table>"
	set groupgrid ""
	foreach test [lrange $featured 1 end] {
	    if { ! [regexp {^(.*)\s+([\w.]+)$} $test res gg name] } {
		set gg UNKNOWN
		set name "Error building short list; check details"
	    }
	    if { $gg != $groupgrid } {
		if { $groupgrid != "" } { puts $fd "</tr>" }
		set groupgrid $gg
		puts $fd "<tr><td>$gg</td>"
	    }
	    puts $fd "<td bgcolor=\"[_html_color $status]\"><a href=\"[regsub -all { } $gg /]/${name}.html\">$name</a></td>"
	}
	if { $groupgrid != "" } { puts $fd "</tr>" }
	puts $fd "</table>"
    }

    # put detailed log
    puts $fd "<h1>Details</h1>"

    # process log line-by-line
    set group {}
    set letter {}
    foreach line [lsort -dictionary [split $log "\n"]] {
	# check that the line is case report in the form "CASE group grid name: result (explanation)"
	if { ! [regexp $_test_case_regexp $line res grp grd casename result message] } {
	    continue
	}

	# start new group
	if { $grp != $group } {
	    if { $letter != "" } { puts $fd "</tr></table>" }
	    set letter {}
	    set group $grp
	    set grid {}
	    puts $fd "<h2>Group $group</h2>"
	}

	# start new grid
	if { $grd != $grid } {
	    if { $letter != "" } { puts $fd "</tr></table>" }
	    set letter {}
	    set grid $grd
	    puts $fd "<h3>Grid $grid</h3>"
	}

	# check if test case name is <letter><digit>; 
	# if not, set alnum to period "." to recognize non-standard test name
	if { ! [regexp {([A-Za-z]+)([0-9]+)} $casename res alnum number] } {
	    set alnum .
	}

	# start new row when letter changes or for non-standard names
	if { $alnum != $letter || $alnum == "." } {
	    if { $letter != "" } { 
		puts $fd "</tr><tr>" 
	    } else {
		puts $fd "<table><tr>"
	    }
	    set letter $alnum
	}	    

	puts $fd "<td bgcolor=\"[_html_color $result]\"><a href=\"$group/$grid/${casename}.html\">$casename</a></td>"
    }
    puts $fd "</tr></table>"

    # add remaining lines of log as plain text
    puts $fd "<h2>Plain text messages</h2>\n<pre>"
    foreach line [split $log "\n"] {
	if { ! [regexp $_test_case_regexp $line] } {
	    puts $fd "$line"
	}
    }
    puts $fd "</pre>"

    # close file and exit
    puts $fd "</body>"
    close $fd
    return
}

# Procedure to dump summary logs of tests
proc _log_summarize {logdir log {total_time {}}} {

    # sort log records alphabetically to have the same behavior on Linux and Windows 
    # (also needed if tests are run in parallel)
    set loglist [lsort -dictionary [split $log "\n"]]

    # classify test cases by status
    foreach line $loglist {
	if { [regexp {^CASE ([^:]*): ([[:alnum:]]+).*$} $line res caseid status] } {
	    lappend stat($status) $caseid
	}
    }
    set totals {}
    set improvements {Improvements:}
    set regressions {Failed:}
    if { [info exists stat] } {
	foreach status [lsort [array names stat]] {
	    lappend totals [list [llength $stat($status)] $status]

	    # separately count improvements (status starting with IMP) and regressions (all except IMP, OK, BAD, and SKIP)
	    if { [regexp -nocase {^IMP} $status] } {
		eval lappend improvements $stat($status)
	    } elseif { $status != "OK" && ! [regexp -nocase {^BAD} $status] && ! [regexp -nocase {^SKIP} $status] } {
		eval lappend regressions $stat($status)
	    }
	}
    }

    # if time is specified, add totals
    if { $total_time != "" } {
	if { [llength $improvements] > 1 } {
	    _log_and_puts log [join $improvements "\n  "]
	}
	if { [llength $regressions] > 1 } {
	    _log_and_puts log [join $regressions "\n  "]
	}
	if { [llength $improvements] == 1 && [llength $regressions] == 1 } {
	    _log_and_puts log "No regressions"
	}
	_log_and_puts log "Total cases: [join $totals {, }]"
	_log_and_puts log $total_time
    }

    # save log to files
    if { $logdir != "" } {
	_log_html_summary $logdir $log $totals $regressions $improvements $total_time
	_log_save $logdir/tests.log $log "Tests summary"
    }

    return
}

# Internal procedure to generate XML log in JUnit style, for further
# consumption by Jenkins or similar systems.
#
# The output is intended to conform to XML schema supported by Jenkins found at
# https://svn.jenkins-ci.org/trunk/hudson/dtkit/dtkit-format/dtkit-junit-model/src/main/resources/com/thalesgroup/dtkit/junit/model/xsd/junit-4.xsd
#
# The mapping of the fields is inspired by annotated schema of Apache Ant JUnit XML format found at
# http://windyroad.org/dl/Open%20Source/JUnit.xsd
proc _log_xml_summary {logdir filename log include_cout} {
    global _test_case_regexp

    catch {file mkdir [file dirname $filename]}

    # try to open a file and start XML
    if [catch {set fd [open $filename w]} res] {
	error "Error creating XML summary file $filename: $res"
    }
    puts $fd "<?xml version='1.0' encoding='utf-8'?>"
    puts $fd "<testsuites>"

    # prototype for command to generate test suite tag
    set time_and_host "timestamp=\"[clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S}]\" hostname=\"[info hostname]\""
    set cmd_testsuite {puts $fd "<testsuite name=\"$group $grid\" tests=\"$nbtests\" failures=\"$nbfail\" errors=\"$nberr\" time=\"$time\" skipped=\"$nbskip\" $time_and_host>\n$testcases\n</testsuite>\n"}

    # sort log and process it line-by-line
    set group {}
    foreach line [lsort -dictionary [split $log "\n"]] {
	# check that the line is case report in the form "CASE group grid name: result (explanation)"
	if { ! [regexp $_test_case_regexp $line res grp grd casename result message] } {
	    continue
	}
	set message [string trim $message " \t\r\n()"]

	# start new testsuite for each grid
	if { $grp != $group || $grd != $grid } {

	    # write previous test suite
	    if [info exists testcases] { eval $cmd_testsuite }

	    set testcases {}
	    set nbtests 0
	    set nberr 0
	    set nbfail 0
	    set nbskip 0
	    set time 0.

	    set group $grp
	    set grid $grd
	}

	incr nbtests
	 
	# parse test log and get its CPU time
	set testout {}
	set add_cpu {}
	if { [catch {set fdlog [open $logdir/$group/$grid/${casename}.log r]} ret] } { 
	    puts "Error: cannot open $logdir/$group/$grid/${casename}.log: $ret"
	} else {
	    while { [gets $fdlog logline] >= 0 } {
		if { $include_cout } {
        	    set testout "$testout$logline\n"
		}
		if [regexp -nocase {TOTAL CPU TIME:\s*([\d.]+)\s*sec} $logline res cpu] {
		    set add_cpu " time=\"$cpu\""
		    set time [expr $time + $cpu]
		}
	    }
	    close $fdlog
	}
	if { ! $include_cout } {
            set testout "$line\n"
	}

	# record test case with its output and status
	# Mapping is: SKIPPED, BAD, and OK to OK, all other to failure
	set testcases "$testcases\n  <testcase name=\"$casename\"$add_cpu status=\"$result\">\n"
	set testcases "$testcases\n    <system-out>\n$testout    </system-out>"
	if { $result != "OK" } {
	    if { [regexp -nocase {^SKIP} $result] } {
		incr nberr
		set testcases "$testcases\n    <error name=\"$result\" message=\"$message\"/>"
	    } elseif { [regexp -nocase {^BAD} $result] } {
		incr nbskip
		set testcases "$testcases\n    <skipped>$message</skipped>"
	    } else {
		incr nbfail
		set testcases "$testcases\n    <failure name=\"$result\" message=\"$message\"/>"
	    }
	}
	set testcases "$testcases\n  </testcase>"
    }

    # write last test suite
    if [info exists testcases] { eval $cmd_testsuite }

    # the end
    puts $fd "</testsuites>"
    close $fd
    return
}

# define custom platform name 
proc _tests_platform_def {} {
    global env tcl_platform

    if [info exists env(os_type)] { return }

    set env(os_type) $tcl_platform(platform)

    # use detailed mapping for various versions of Lunix
    # (note that mapping is rather non-uniform, for historical reasons)
    if { $env(os_type) == "unix" && ! [catch {exec cat /etc/issue} issue] } {
	if { [regexp {Mandriva[ \tA-Za-z]+([0-9]+)} $issue res num] } {
	    set env(os_type) Mandriva$num
	} elseif { [regexp {Red Hat[ \tA-Za-z]+([0-9]+)} $issue res num] } {
	    set env(os_type) RedHat$num
	} elseif { [regexp {Debian[ \tA-Za-z/]+([0-9]+)[.]([0-9]+)} $issue res num subnum] } {
	    set env(os_type) Debian$num$subnum
	} elseif { [regexp {CentOS[ \tA-Za-z]+([0-9]+)[.]([0-9]+)} $issue res num subnum] } {
	    set env(os_type) CentOS$num$subnum
	} elseif { [regexp {Scientific[ \tA-Za-z]+([0-9]+)[.]([0-9]+)} $issue res num subnum] } {
	    set env(os_type) SL$num$subnum
	} elseif { [regexp {Fedora Core[ \tA-Za-z]+([0-9]+)} $issue res num] } {
	    set env(os_type) FedoraCore$num
	}
	if { [exec uname -m] == "x86_64" } {
	    set env(os_type) "$env(os_type)-64"
	}
    }
}
_tests_platform_def

# Auxiliary procedure to split path specification (usually defined by
# environment variable) into list of directories or files
proc _split_path {pathspec} {
    global tcl_platform

    # first replace all \ (which might occur on Windows) by /  
    regsub -all "\\\\" $pathspec "/" pathspec

    # split path by platform-specific separator
    return [split $pathspec [_path_separator]]
}

# Auxiliary procedure to define platform-specific separator for directories in
# path specification
proc _path_separator {} {
    global tcl_platform

    # split path by platform-specific separator
    if { $tcl_platform(platform) == "windows" } {
	return ";"
    } else {
	return ":"
    }
}

# Procedure to locate data file for test given its name.
# The search is performed assuming that the function is called 
# from the test case script; the search order is:
# - directory where test script is located
# - directories ../data and ../../data from the script dir
# - subdirectories <group>/<grid> and <group> of directories listed in 
#   environment variable CSF_TestDataPath
# If file is not found, raises Tcl error.
proc locate_data_file {filename} {
    global env groupname gridname casename

    set scriptfile [info script]
    if { $scriptfile == "" } {
	error "Error: This procedure (locate_data_file) is for use only in test scripts!"
    }

    # check sub-directories data of the test case grid directory
    # the current test case in paths indicated by CSF_TestScriptsPath
    if { [info exists groupname] && [info exists gridname] && 
         [info exists env(CSF_TestScriptsPath)] } {
	foreach dir [_split_path $env(CSF_TestScriptsPath)] {
	    if { [file exists $dir/$groupname/$gridname/data/$filename] } {
		return [file normalize $dir/$groupname/$gridname/data/$filename]
	    }
	    if { [file exists $dir/$groupname/data/$filename] } {
		return [file normalize $dir/$groupname/data/$filename]
	    }
	}
    }

    # check sub-directories corresponding to group and grid of
    # the current test case in paths indicated by CSF_TestDataPath
    if { [info exists groupname] && [info exists env(CSF_TestDataPath)] } {
	foreach dir [_split_path $env(CSF_TestDataPath)] {
	    if { [info exists gridname] && [file exists $dir/$groupname/$gridname/$filename] } {
		return [file normalize $dir/$groupname/$gridname/$filename]
	    }
	    if { [file exists $dir/$groupname/$filename] } {
		return [file normalize $dir/$groupname/$filename]
	    }
	}
    }

    # check datadir
    if { [file exists [uplevel datadir]/$filename] } {
	return [uplevel datadir]/$filename
    }

    # raise error
    error [join [list "Error: file $filename could not be found neither in script" \
		      "directories nor in paths indicated by CSF_TestDataPath environment variable"] "\n"]
}

# Procedure to make a diff and common of two lists
proc _list_diff {list1 list2 _in1 _in2 _common} {
    upvar $_in1 in1
    upvar $_in2 in2
    upvar $_common common

    set in1 {}
    set in2 {}
    set common {}
    foreach item $list1 {
	if { [lsearch -exact $list2 $item] >= 0 } {
	    lappend common $item
        } else {
	    lappend in1 $item
	}
    }
    foreach item $list2 {
	if { [lsearch -exact $common $item] < 0 } {
	    lappend in2 $item
	}
    }
    return
}

# procedure to load a file to Tcl string
proc _read_file {filename} {
    set fd [open $filename r]
    set result [read -nonewline $fd]
    close $fd
    return $result
}

# Procedure to compare results of two runs of test cases
proc _test_diff {dir1 dir2 basename status verbose _logvar {_statvar ""}} {
    upvar $_logvar log

    # prepare variable (array) for collecting statistics
    if { "$_statvar" != "" } {
        upvar $_statvar stat
    } else {
        set stat(cpu1) 0
        set stat(cpu2) 0
        set log {}
    }

    # first check subdirectories
    set path1 [file join $dir1 $basename]
    set path2 [file join $dir2 $basename]
    set list1 [glob -directory $path1 -types d -tails -nocomplain *]
    set list2 [glob -directory $path2 -types d -tails -nocomplain *]
    if { [llength $list1] >0 || [llength $list2] > 0 } {
        _list_diff $list1 $list2 in1 in2 common
        if { "$verbose" > 1 } {
            if { [llength $in1] > 0 } { _log_and_puts log "Only in $path1: $in1" }
            if { [llength $in2] > 0 } { _log_and_puts log "Only in $path2: $in2" }
        }
        foreach subdir $common {
            if { "$verbose" > 2 } {
	        _log_and_puts log "Checking [file join $basename $subdir]"
	    }
	    _test_diff $dir1 $dir2 [file join $basename $subdir] $status $verbose log stat
        }
    } else {
        # check log files (only if directory has no subdirs)
        set list1 [glob -directory $path1 -types f -tails -nocomplain *.log]
        set list2 [glob -directory $path2 -types f -tails -nocomplain *.log]
        _list_diff $list1 $list2 in1 in2 common
        if { "$verbose" > 1 } {
            if { [llength $in1] > 0 } { _log_and_puts log "Only in $path1: $in1" }
            if { [llength $in2] > 0 } { _log_and_puts log "Only in $path2: $in2" }
        }
        foreach logfile $common {
            # load two logs
	    set log1 [_read_file [file join $dir1 $basename $logfile]]
	    set log2 [_read_file [file join $dir2 $basename $logfile]]

            # check execution statuses
            set status1 UNDEFINED
            set status2 UNDEFINED
	    if { ! [regexp {CASE [^:]*:\s*([\w]+)} $log1 res1 status1] ||
	         ! [regexp {CASE [^:]*:\s*([\w]+)} $log2 res2 status2] ||
	         "$status1" != "$status2" } {
	        _log_and_puts log "STATUS [split $basename /] [file rootname $logfile]: $status1 / $status2"

                # if test statuses are different, further comparison makes 
 		# no sense unless explicitly requested
		if { "$status" != "all" } {
                    continue
		}
	    }
	    if { "$status" == "ok" && "$status1" != "OK" } { 
		continue
	    }

            # check CPU times
            set cpu1 UNDEFINED
            set cpu2 UNDEFINED
	    if { [regexp {TOTAL CPU TIME:\s*([\d.]+)} $log1 res1 cpu1] &&
	         [regexp {TOTAL CPU TIME:\s*([\d.]+)} $log2 res1 cpu2] } {
                set stat(cpu1) [expr $stat(cpu1) + $cpu1]
                set stat(cpu2) [expr $stat(cpu2) + $cpu2]

                # compare CPU times with 10% precision (but not less 0.5 sec)
	        if { [expr abs ($cpu1 - $cpu2) > 0.5 + 0.05 * abs ($cpu1 + $cpu2)] } {
	            _log_and_puts log "CPU [split $basename /] [file rootname $logfile]: $cpu1 / $cpu2"
                }
	    }
	}
    }

    if { "$_statvar" == "" } {
        _log_and_puts log "Total CPU difference: $stat(cpu1) / $stat(cpu2)"
    }
}
