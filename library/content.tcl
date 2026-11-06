proc ::web::wiki::fail {status message} {
    return -code error -errorcode [list WEB WIKI $status] $message
}

proc ::web::wiki::options {defaults args} {
    if {[llength $args] % 2} {error "options must be name/value pairs"}
    foreach {key value} $args {
        if {![dict exists $defaults $key]} {error "unknown option: $key"}
        dict set defaults $key $value
    }
    return $defaults
}

proc ::web::wiki::create {args} {
    set config [options {-connection {} -domain default -title {}} {*}$args]
    if {[dict get $config -connection] eq {}} {error "-connection is required"}
    set domain [dict get $config -domain]
    if {![regexp {^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$} $domain]} {error "invalid domain"}
    if {[dict get $config -title] eq {}} {dict set config -title Wiki}
    dict set config kind wiki
    dict set config -domain [string tolower $domain]
    return $config
}

proc ::web::wiki::scope {store statement} {
    db_where $statement [db_eq [db_col domain] [db_value [dict get $store -domain]]]
}

proc ::web::wiki::execute {store statement} {
    db_execute [dict get $store -connection] [scope $store $statement]
}

proc ::web::wiki::identity {store path} {
    dict create domain [dict get $store -domain] path $path
}

proc ::web::wiki::path_filter {statement path} {
    db_where $statement [db_eq [db_col path] [db_value $path]]
}

proc ::web::wiki::canonical_path {path} {
    if {$path eq "/"} {return /}
    if {![regexp {^(/[a-z0-9]+(-[a-z0-9]+)*)+$} $path] || [string length $path] > 1024} {
        fail 400 "invalid content path"
    }
    return $path
}

proc ::web::wiki::load {store path {includeInactive 0}} {
    canonical_path $path
    set query [path_filter [db_select web_wiki_items] $path]
    if {!$includeInactive} {set query [db_where $query -expr {active = TRUE}]}
    set rows [dict get [execute $store $query] rows]
    if {![llength $rows]} {fail 404 "content not found"}
    return [lindex $rows 0]
}

proc ::web::wiki::children {store path} {
    canonical_path $path
    set query [db_where [db_select web_wiki_items] [db_and \
        [db_eq [db_col parent_path] [db_value $path]] \
        [db_eq [db_col active] [db_value 1]] \
        [db_ne [db_col path] [db_value $path]]]]
    dict get [execute $store [db_order_by $query -expr {item_type ASC, title ASC, path ASC}]] rows
}

proc ::web::wiki::history {store path} {
    canonical_path $path
    set query [path_filter [db_select web_wiki_revisions] $path]
    dict get [execute $store [db_order_by $query -expr {revision DESC}]] rows
}

proc ::web::wiki::now {} {clock format [clock seconds] -gmt 1 -format %Y-%m-%dT%H:%M:%SZ}

proc ::web::wiki::append_revision {store item} {
    set values [dict merge [identity $store [dict get $item path]] [dict create \
        revision [dict get $item revision] title [dict get $item title] \
        markdown [dict get $item markdown] created_at [dict get $item updated_at]]]
    db_execute [dict get $store -connection] [db_values [db_insert web_wiki_revisions] $values]
}

proc ::web::wiki::save {store path title markdown expectedRevision} {
    canonical_path $path
    # Browser form submission uses CRLF; imports and stored Markdown use LF.
    set markdown [string map [list "\r\n" "\n" "\r" "\n"] $markdown]
    if {![string is integer -strict $expectedRevision] || $expectedRevision < 1} {
        fail 400 "invalid revision"
    }
    set title [string trim $title]
    if {$title eq {} || [string length $title] > 300 || [string first \x00 $title] >= 0} {
        fail 400 "title must contain between 1 and 300 characters"
    }
    if {[string length [encoding convertto utf-8 $markdown]] > 1048576 || [string first \x00 $markdown] >= 0} {
        fail 413 "Markdown exceeds the size limit or contains NUL"
    }
    db_transaction [dict get $store -connection] {
        set item [load $store $path]
        if {[dict get $item item_type] ne "page"} {fail 400 "only pages can be edited"}
        if {[dict get $item revision] != $expectedRevision} {fail 409 "page changed; reload before saving"}
        if {[dict get $item title] eq $title && [dict get $item markdown] eq $markdown} {return $item}
        set changes [dict create title $title markdown $markdown \
            revision [expr {$expectedRevision + 1}] updated_at [now]]
        set update [path_filter [db_values [db_update web_wiki_items] $changes] $path]
        set update [db_where $update [db_eq [db_col revision] [db_value $expectedRevision]]]
        if {[dict get [execute $store $update] rowcount] != 1} {fail 409 "page changed; reload before saving"}
        set item [dict merge $item $changes]
        append_revision $store $item
    }
    return $item
}

proc ::web::wiki::slug {text} {
    set text [string tolower [string trim $text]]
    regsub -all {[^a-z0-9[:space:]-]} $text {} text
    regsub -all {[[:space:]-]+} $text - text
    set text [string trim $text -]
    if {$text eq {}} {set text wiki-item}
    return $text
}

proc ::web::wiki::title {markdown filename} {
    foreach line [split $markdown \n] {
        if {[regexp {^#{1,6}[ \t]+(.+)$} $line -> title]} {
            set title [string trim [string trimright [string trim $title] #]]
            if {$title ne {}} {return $title}
        }
    }
    return [file rootname [file tail $filename]]
}

proc ::web::wiki::read_file {filename {limit 1048576}} {
    if {[file size $filename] > $limit} {fail 413 "source file exceeds size limit: $filename"}
    set channel [open $filename r]
    try {
        fconfigure $channel -encoding utf-8 -translation auto
        set text [read $channel]
    } finally {close $channel}
    if {[string first \x00 $text] >= 0} {fail 400 "NUL in source file: $filename"}
    return $text
}

proc ::web::wiki::add_source {itemsVar path item} {
    upvar 1 $itemsVar items
    canonical_path $path
    if {[dict exists $items $path]} {fail 409 "duplicate content URL: $path"}
    dict set item path $path
    dict set items $path $item
}

proc ::web::wiki::scan {store directory relative parent itemsVar} {
    upvar 1 $itemsVar items
    foreach filename [lsort [glob -nocomplain -directory $directory *]] {
        set name [file tail $filename]
        set source [expr {$relative eq {} ? $name : "$relative/$name"}]
        set type [file type $filename]
        if {$type eq "link"} {fail 400 "symbolic links are not content sources: $source"}
        set prefix [string trimright $parent /]
        if {$type eq "directory"} {
            set path $prefix/[slug $name]
            add_source items $path [dict create parent_path $parent item_type folder title $name \
                markdown {} source_markdown {} source_path $source]
            scan $store $filename $source $path items
        } elseif {$type eq "file" && [string tolower [file extension $filename]] in {.md .markdown}} {
            set markdown [read_file $filename]
            set title [title $markdown $name]
            set pageSlug [slug $title]
            add_source items $prefix/$pageSlug [dict create parent_path $parent item_type page \
                title $title markdown $markdown source_markdown $markdown source_path $source]
        }
    }
}

proc ::web::wiki::sync {store directory} {
    if {![file isdirectory $directory] || [file type $directory] eq "link"} {
        fail 400 "content source must be an existing directory"
    }
    set items {}
    add_source items / [dict create parent_path / item_type folder title [dict get $store -title] \
        markdown {} source_markdown {} source_path {}]
    # Complete validation before starting any database writes.
    scan $store [file normalize $directory] {} / items
    set counts {created 0 revised 0 reactivated 0 deactivated 0}
    db_transaction [dict get $store -connection] {
        set existing {}
        foreach row [dict get [execute $store [db_select web_wiki_items]] rows] {
            dict set existing [dict get $row path] $row
        }
        dict for {path source} $items {
            set timestamp [now]
            set isPage [expr {[dict get $source item_type] eq "page"}]
            if {![dict exists $existing $path]} {
                set item [dict merge [identity $store $path] $source \
                    [dict create revision $isPage active 1 updated_at $timestamp]]
                db_execute [dict get $store -connection] [db_values [db_insert web_wiki_items] $item]
                if {$isPage} {append_revision $store $item}
                dict incr counts created
                continue
            }
            set old [dict get $existing $path]
            if {[dict get $old item_type] ne [dict get $source item_type]} {
                fail 409 "content type changed at $path"
            }
            set changed [expr {[dict get $old source_markdown] ne [dict get $source source_markdown]}]
            set changes [dict create active 1 source_path [dict get $source source_path]]
            if {$changed || !$isPage} {set changes [dict merge $changes $source]}
            if {$isPage && $changed} {
                dict set changes revision [expr {[dict get $old revision] + 1}]
                dict incr counts revised
            }
            if {![dict get $old active]} {dict incr counts reactivated}
            if {$changed || ![dict get $old active]} {dict set changes updated_at $timestamp}
            execute $store [path_filter [db_values [db_update web_wiki_items] $changes] $path]
            if {$isPage && $changed} {append_revision $store [dict merge $old $changes]}
        }
        dict for {path old} $existing {
            if {![dict exists $items $path] && [dict get $old active]} {
                execute $store [path_filter [db_values [db_update web_wiki_items] \
                    [dict create active 0 updated_at [now]]] $path]
                dict incr counts deactivated
            }
        }
    }
    return $counts
}
