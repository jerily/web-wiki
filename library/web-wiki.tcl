# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

# Load the wiki package and its storage dependencies.
package require web-wiki::manifest
package require Tcl
package require tpersist
package require cmark_gfm
package require tpathexp
package require jinja2
package require tjson

namespace eval ::web::wiki {
    variable root [file dirname [file dirname [info script]]]
    namespace import ::tpersist::db_*
}
source [file join $::web::wiki::root library content.tcl]
source [file join $::web::wiki::root library initdb.tcl]
source [file join $::web::wiki::root library templates.tcl]
source [file join $::web::wiki::root library http.tcl]
source [file join $::web::wiki::root library mount.tcl]
package provide web-wiki 1.0.0
