package require Tcl 8.6 9
package require tpersist 0.1.0
package require cmark_gfm 0.1.0
package require tpathexp 1.1.0
package require jinja2 0.1.0
package require tjson 1.0.26

namespace eval ::web::wiki {
    variable root [file dirname [file dirname [info script]]]
    namespace import ::tpersist::db_*
}
source [file join $::web::wiki::root library content.tcl]
source [file join $::web::wiki::root library initdb.tcl]
source [file join $::web::wiki::root library templates.tcl]
source [file join $::web::wiki::root library http.tcl]
source [file join $::web::wiki::root library mount.tcl]
package provide web-wiki 0.1.1
