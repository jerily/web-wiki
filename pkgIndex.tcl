if {![package vsatisfies [package provide Tcl] 8.6-10]} {return}
package ifneeded web-wiki 0.1.1 [list source [file join $dir library web-wiki.tcl]]
