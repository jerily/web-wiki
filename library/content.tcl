proc ::web::content::fail {status message} {
    return -code error -errorcode [list WEB CONTENT $status] $message
}

proc ::web::content::options {defaults args} {
    if {[llength $args] % 2} {error "options must be name/value pairs"}
    foreach {key value} $args {
        if {![dict exists $defaults $key]} {error "unknown option: $key"}
        dict set defaults $key $value
    }
    return $defaults
}

proc ::web::content::create {kind args} {
    set config [options {-connection {} -domain default -title {}} {*}$args]
    if {[dict get $config -connection] eq {}} {error "-connection is required"}
    set domain [dict get $config -domain]
    if {![regexp {^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$} $domain]} {error "invalid domain"}
    if {[dict get $config -title] eq {}} {dict set config -title [string totitle $kind]}
    dict set config kind $kind
    dict set config -domain [string tolower $domain]
    return $config
}

# Explicit maintenance operation. Mounting and handling requests never create schema.
proc ::web::content::initdb {connection} {
    set identity {
        collection {type varchar length 16 not_null 1}
        domain {type varchar length 253 not_null 1}
        path {type varchar length 1024 not_null 1}
    }
    set items [db_define_table web_content_items [dict merge $identity {
        parent_path {type text not_null 1}
        item_type {type varchar length 16 not_null 1}
        title {type text not_null 1}
        markdown {type text not_null 1}
        source_path {type text not_null 1}
        source_markdown {type text not_null 1}
        published_at {type varchar length 10 not_null 1}
        revision {type integer not_null 1}
        active {type boolean not_null 1}
        updated_at {type varchar length 32 not_null 1}
    }] -primary_key {collection domain path}]
    set revisions [db_define_table web_content_revisions [dict merge $identity {
        revision {type integer not_null 1}
        title {type text not_null 1}
        markdown {type text not_null 1}
        created_at {type varchar length 32 not_null 1}
    }] -primary_key {collection domain path revision}]
    db_create_table $connection $items -if_not_exists 1
    db_create_table $connection $revisions -if_not_exists 1
}

proc ::web::content::scope {store statement} {
    db_where $statement [db_and \
        [db_eq [db_col collection] [db_value [dict get $store kind]]] \
        [db_eq [db_col domain] [db_value [dict get $store -domain]]]]
}

proc ::web::content::execute {store statement} {
    db_execute [dict get $store -connection] [scope $store $statement]
}

proc ::web::content::identity {store path} {
    dict create collection [dict get $store kind] domain [dict get $store -domain] path $path
}

proc ::web::content::path_filter {statement path} {
    db_where $statement [db_eq [db_col path] [db_value $path]]
}

proc ::web::content::canonical_path {path} {
    if {$path eq "/"} {return /}
    if {![regexp {^(/[a-z0-9]+(-[a-z0-9]+)*)+$} $path] || [string length $path] > 1024} {
        fail 400 "invalid content path"
    }
    return $path
}

proc ::web::content::load {store path {includeInactive 0}} {
    canonical_path $path
    set query [path_filter [db_select web_content_items] $path]
    if {!$includeInactive} {set query [db_where $query -expr {active = TRUE}]}
    set rows [dict get [execute $store $query] rows]
    if {![llength $rows]} {fail 404 "content not found"}
    return [lindex $rows 0]
}

proc ::web::content::children {store path} {
    canonical_path $path
    set query [db_where [db_select web_content_items] [db_and \
        [db_eq [db_col parent_path] [db_value $path]] \
        [db_eq [db_col active] [db_value 1]] \
        [db_ne [db_col path] [db_value $path]]]]
    dict get [execute $store [db_order_by $query -expr {item_type ASC, title ASC, path ASC}]] rows
}

proc ::web::content::posts {store} {
    set query [db_where [db_select web_content_items] -expr {active = TRUE AND item_type = 'page'}]
    dict get [execute $store [db_order_by $query -expr {published_at DESC, path ASC}]] rows
}

proc ::web::content::history {store path} {
    canonical_path $path
    set query [path_filter [db_select web_content_revisions] $path]
    dict get [execute $store [db_order_by $query -expr {revision DESC}]] rows
}

proc ::web::content::now {} {clock format [clock seconds] -gmt 1 -format %Y-%m-%dT%H:%M:%SZ}

proc ::web::content::append_revision {store item} {
    set values [dict merge [identity $store [dict get $item path]] [dict create \
        revision [dict get $item revision] title [dict get $item title] \
        markdown [dict get $item markdown] created_at [dict get $item updated_at]]]
    db_execute [dict get $store -connection] [db_values [db_insert web_content_revisions] $values]
}

proc ::web::content::save {store path title markdown expectedRevision} {
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
        set update [path_filter [db_values [db_update web_content_items] $changes] $path]
        set update [db_where $update [db_eq [db_col revision] [db_value $expectedRevision]]]
        if {[dict get [execute $store $update] rowcount] != 1} {fail 409 "page changed; reload before saving"}
        set item [dict merge $item $changes]
        append_revision $store $item
    }
    return $item
}

proc ::web::content::slug {text} {
    set text [string tolower [string trim $text]]
    regsub -all {[^a-z0-9[:space:]-]} $text {} text
    regsub -all {[[:space:]-]+} $text - text
    set text [string trim $text -]
    if {$text eq {}} {set text wiki-item}
    return $text
}

proc ::web::content::title {markdown filename} {
    foreach line [split $markdown \n] {
        if {[regexp {^#{1,6}[ \t]+(.+)$} $line -> title]} {
            set title [string trim [string trimright [string trim $title] #]]
            if {$title ne {}} {return $title}
        }
    }
    return [file rootname [file tail $filename]]
}

proc ::web::content::read_file {filename {limit 1048576}} {
    if {[file size $filename] > $limit} {fail 413 "source file exceeds size limit: $filename"}
    set channel [open $filename r]
    try {
        fconfigure $channel -encoding utf-8 -translation auto
        set text [read $channel]
    } finally {close $channel}
    if {[string first \x00 $text] >= 0} {fail 400 "NUL in source file: $filename"}
    return $text
}

proc ::web::content::add_source {itemsVar path item} {
    upvar 1 $itemsVar items
    canonical_path $path
    if {[dict exists $items $path]} {fail 409 "duplicate content URL: $path"}
    dict set item path $path
    dict set items $path $item
}

proc ::web::content::scan {store directory relative parent itemsVar} {
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
                markdown {} source_markdown {} source_path $source published_at {}]
            scan $store $filename $source $path items
        } elseif {$type eq "file" && [string tolower [file extension $filename]] in {.md .markdown}} {
            set markdown [read_file $filename]
            set title [title $markdown $name]
            set date {}
            set pageSlug [slug $title]
            if {[dict get $store kind] eq "blog"} {
                if {![regexp -nocase {^([0-9]{4}-[0-9]{2}-[0-9]{2})-.+\.(md|markdown)$} $name -> date] ||
                    [catch {clock scan $date -format %Y-%m-%d -gmt 1} seconds] ||
                    [clock format $seconds -format %Y-%m-%d -gmt 1] ne $date} {
                    fail 400 "blog filenames must start with a valid YYYY-MM-DD- date: $source"
                }
                set title [title $markdown [string range $name 11 end]]
                set pageSlug $date-[slug $title]
            }
            add_source items $prefix/$pageSlug [dict create parent_path $parent item_type page \
                title $title markdown $markdown source_markdown $markdown source_path $source published_at $date]
        }
    }
}

proc ::web::content::sync {store directory} {
    if {![file isdirectory $directory] || [file type $directory] eq "link"} {
        fail 400 "content source must be an existing directory"
    }
    set items {}
    add_source items / [dict create parent_path / item_type folder title [dict get $store -title] \
        markdown {} source_markdown {} source_path {} published_at {}]
    # Complete validation before starting any database writes.
    scan $store [file normalize $directory] {} / items
    set counts {created 0 revised 0 reactivated 0 deactivated 0}
    db_transaction [dict get $store -connection] {
        set existing {}
        foreach row [dict get [execute $store [db_select web_content_items]] rows] {
            dict set existing [dict get $row path] $row
        }
        dict for {path source} $items {
            set timestamp [now]
            set isPage [expr {[dict get $source item_type] eq "page"}]
            if {![dict exists $existing $path]} {
                set item [dict merge [identity $store $path] $source \
                    [dict create revision $isPage active 1 updated_at $timestamp]]
                db_execute [dict get $store -connection] [db_values [db_insert web_content_items] $item]
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
            execute $store [path_filter [db_values [db_update web_content_items] $changes] $path]
            if {$isPage && $changed} {append_revision $store [dict merge $old $changes]}
        }
        dict for {path old} $existing {
            if {![dict exists $items $path] && [dict get $old active]} {
                execute $store [path_filter [db_values [db_update web_content_items] \
                    [dict create active 0 updated_at [now]]] $path]
                dict incr counts deactivated
            }
        }
    }
    return $counts
}
