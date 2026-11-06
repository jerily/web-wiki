proc ::web::wiki::response {status body {type {text/html; charset=utf-8}}} {
    dict create statusCode $status body $body headers [dict create \
        content-type $type x-content-type-options nosniff cache-control no-store \
        content-security-policy {default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' https: data:; base-uri 'none'; form-action 'self'; frame-ancestors 'none'}]
}

proc ::web::wiki::url {config path} {
    set prefix [dict get $config -prefix]
    if {$path eq "/"} {return [expr {$prefix eq {} ? "/" : $prefix}]}
    return $prefix$path
}

proc ::web::wiki::decode {value {form 0}} {
    if {$form} {set value [string map {+ { }} $value]}
    set bytes {}
    for {set i 0} {$i < [string length $value]} {incr i} {
        set character [string index $value $i]
        if {$character eq "%"} {
            set hex [string range $value [expr {$i + 1}] [expr {$i + 2}]]
            if {![regexp {^[0-9a-fA-F]{2}$} $hex]} {fail 400 "invalid percent encoding"}
            append bytes [binary format H2 $hex]
            incr i 2
        } else {append bytes [encoding convertto utf-8 $character]}
    }
    if {[catch {encoding convertfrom utf-8 $bytes} result]} {fail 400 "invalid UTF-8 in request"}
    if {[encoding convertto utf-8 $result] ne $bytes || [string first \x00 $result] >= 0} {
        fail 400 "invalid UTF-8 or NUL in request"
    }
    return $result
}

proc ::web::wiki::request_path {params} {
    if {![dict exists $params path]} {return /}
    set path [string trimright /[decode [dict get $params path]] /]
    if {$path eq {}} {return /}
    # Do not turn traversal, encoded slashes or punctuation into valid identifiers.
    if {[regexp -nocase {%2f|%5c} [dict get $params path]]} {fail 400 "encoded path separators are not accepted"}
    set path [string tolower $path]
    regsub -all { +} $path - path
    return [canonical_path $path]
}

proc ::web::wiki::header {request name} {
    if {[dict exists $request headers]} {
        dict for {key value} [dict get $request headers] {
            if {[string equal -nocase $key $name]} {return $value}
        }
    }
    return {}
}

proc ::web::wiki::form {request} {
    if {[string tolower [string trim [lindex [split [header $request content-type] {;}] 0]]] ne \
        "application/x-www-form-urlencoded"} {fail 415 "expected URL-encoded form data"}
    if {![dict exists $request body]} {fail 400 "missing form body"}
    set body [dict get $request body]
    if {[string length [encoding convertto utf-8 $body]] > 4194304} {fail 413 "form exceeds size limit"}
    if {[dict exists $request isBase64Encoded] && [dict get $request isBase64Encoded]} {
        if {[catch {binary decode base64 -strict $body} body]} {fail 400 "invalid base64 body"}
    }
    set fields {}
    foreach pair [split $body &] {
        set equals [string first = $pair]
        if {$equals < 0} {fail 400 "invalid form field"}
        set key [decode [string range $pair 0 [expr {$equals - 1}]] 1]
        set value [decode [string range $pair [expr {$equals + 1}] end] 1]
        if {[dict exists $fields $key]} {fail 400 "duplicate form field"}
        dict set fields $key $value
    }
    foreach field {title markdown revision csrf} {
        if {![dict exists $fields $field]} {fail 400 "missing form field: $field"}
    }
    return $fields
}

proc ::web::wiki::asset {params} {
    variable root
    set name [dict get $params asset]
    set types {style.css text/css editor.css text/css markdown-editor.bundle.js text/javascript}
    if {![dict exists $types $name]} {fail 404 "asset not found"}
    set result [response 200 [read_file [file join $root assets $name] 2097152] \
        "[dict get $types $name]; charset=utf-8"]
    dict set result headers cache-control {public, max-age=3600}
    return $result
}

proc ::web::wiki::view {config path} {
    set store [dict get $config -store]
    set item [load $store $path]
    set title [dict get $item title]
    if {[dict get $item item_type] eq "folder"} {
        set entries [children $store $path]
        set rows {}
        foreach entry $entries {
            lappend rows [dict create url [url $config [dict get $entry path]] \
                title [dict get $entry title] kind [dict get $entry item_type] \
                date {}]
        }
        set fields [text_fields [dict create title $title]]
        dict set fields entries [rows_field $rows]
        set html [render_page $config index.html.jinja $fields]
    } else {
        set revisions {}
        foreach revision [history $store $path] {
            lappend revisions [dict create number [dict get $revision revision] \
                created_at [dict get $revision created_at]]
        }
        set editUrl {}
        if {[dict get $config -authorize] ne {}} {
            set editUrl [dict get $config -prefix]/_edit$path
        }
        set fields [text_fields [dict create title $title \
            parent [url $config [dict get $item parent_path]] edit_url $editUrl \
            markdown_html [::cmark_gfm::render_gfm_html [dict get $item markdown]] \
            date {}]]
        dict set fields revisions [rows_field $revisions]
        set html [render_page $config item.html.jinja $fields]
    }
    response 200 $html
}

proc ::web::wiki::edit {config request context path} {
    set authorize [dict get $config -authorize]
    set csrf [dict get $config -csrf]
    if {$authorize eq {}} {fail 404 "editing is disabled"}
    set action [expr {[dict get $request method] eq "POST" ? "save" : "edit"}]
    if {![{*}$authorize $request $context $action $path]} {fail 403 "editing is not authorized"}
    set store [dict get $config -store]
    if {$action eq "save"} {
        set fields [form $request]
        if {![{*}$csrf verify $request $context [dict get $fields csrf]]} {fail 403 "invalid CSRF token"}
        save $store $path [dict get $fields title] [dict get $fields markdown] [dict get $fields revision]
        set result [response 303 {}]
        dict set result headers location [url $config $path]
        return $result
    }
    set item [load $store $path]
    if {[dict get $item item_type] ne "page"} {fail 400 "only pages can be edited"}
    set token [{*}$csrf issue $request $context {}]
    if {$token eq {}} {error "CSRF callback returned an empty token"}
    set title "Edit [dict get $item title]"
    set fields [text_fields [dict create title $title item_title [dict get $item title] \
        markdown [dict get $item markdown] csrf $token revision [dict get $item revision] \
        cancel [url $config $path]]]
    dict set fields editing {BOOL 1}
    response 200 [render_page $config edit.html.jinja $fields]
}

proc ::web::wiki::dispatch {config action request context params} {
    try {
        switch -- $action {
            asset {return [asset $params]}
            view {return [view $config [request_path $params]]}
            edit {return [edit $config $request $context [request_path $params]]}
        }
    } trap {WEB WIKI} {message options} {
        return [response [lindex [dict get $options -errorcode] 2] "$message\n" {text/plain; charset=utf-8}]
    }
}
