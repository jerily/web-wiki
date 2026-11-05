package require tcltest 2
lappend auto_path [file dirname [file dirname [file normalize [info script]]]]
::tcltest::configure {*}$argv -singleproc true -testdir [file dirname [file normalize [info script]]]
exit [::tcltest::runAllTests]
