proc ::web::content::mount {kind router args} {
    set config [options [dict create -store {} -prefix /$kind -authorize {} -csrf {} -navigation {}] {*}$args]
    set store [dict get $config -store]
    if {$store eq {} || [dict get $store kind] ne $kind} {error "-store must be a $kind store"}
    set prefix [string trimright [dict get $config -prefix] /]
    if {$prefix ne {}} {canonical_path $prefix}
    dict set config -prefix $prefix
    if {([dict get $config -authorize] eq {}) != ([dict get $config -csrf] eq {})} {
        error "editing requires both -authorize and -csrf command prefixes"
    }
    foreach link [dict get $config -navigation] {
        if {[llength $link] != 2 || ![regexp {^/[^\r\n]*$} [lindex $link 1]] ||
            [string match {//*} [lindex $link 1]]} {error "navigation entries must be {label /local-path}"}
    }
    set index [expr {$prefix eq {} ? "/" : $prefix}]
    if {[dict get [$router match GET $index] statusCode] != 404} {
        error "mount prefix is already handled; mount content before catch-all routes"
    }
    foreach {methods pattern action} {
        GET /_assets/:asset asset
        {GET POST} /_edit/:path(.*) edit
    } {
        $router add $methods $prefix$pattern [list ::web::content::dispatch $config $action] -strict true
    }
    $router add GET $index [list ::web::content::dispatch $config view] -strict true
    if {$prefix ne {}} {
        $router add GET $prefix/ [list ::web::content::dispatch $config view] -strict true
    }
    $router add GET $prefix/:path(.*) [list ::web::content::dispatch $config view] -strict true
    return $config
}

proc ::web::content::escape {value} {
    string map {& &amp; < &lt; > &gt; \" &quot; ' &#39;} $value
}

proc ::web::content::template {name replacements} {
    variable root
    # Templates are external assets; replacements are escaped at their call sites.
    string map $replacements [read_file [file join $root assets $name]]
}

proc ::web::content::response {status body {type {text/html; charset=utf-8}}} {
    dict create statusCode $status body $body headers [dict create \
        content-type $type x-content-type-options nosniff cache-control no-store \
        content-security-policy {default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' https: data:; base-uri 'none'; form-action 'self'; frame-ancestors 'none'}]
}

proc ::web::content::url {config path} {
    set prefix [dict get $config -prefix]
    if {$path eq "/"} {return [expr {$prefix eq {} ? "/" : $prefix}]}
    return $prefix$path
}

proc ::web::content::shell {config title body {editing 0}} {
    set nav {}
    foreach link [dict get $config -navigation] {
        lassign $link label href
        append nav "<a href=\"[escape $href]\">[escape $label]</a> "
    }
    set assets [dict get $config -prefix]/_assets
    set script {}
    if {$editing} {set script "<script defer src=\"$assets/markdown-editor.bundle.js\"></script>"}
    template page.html [list @title@ [escape $title] @brand@ [escape [dict get $config -store -title]] \
        @home@ [url $config /] @nav@ $nav @assets@ $assets @body@ $body @script@ $script]
}

proc ::web::content::decode {value {form 0}} {
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

proc ::web::content::request_path {params} {
    if {![dict exists $params path]} {return /}
    set path [string trimright /[decode [dict get $params path]] /]
    if {$path eq {}} {return /}
    # Do not turn traversal, encoded slashes or punctuation into valid identifiers.
    if {[regexp -nocase {%2f|%5c} [dict get $params path]]} {fail 400 "encoded path separators are not accepted"}
    set path [string tolower $path]
    regsub -all { +} $path - path
    return [canonical_path $path]
}

proc ::web::content::header {request name} {
    if {[dict exists $request headers]} {
        dict for {key value} [dict get $request headers] {
            if {[string equal -nocase $key $name]} {return $value}
        }
    }
    return {}
}

proc ::web::content::form {request} {
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

proc ::web::content::asset {params} {
    variable root
    set name [dict get $params asset]
    set types {style.css text/css editor.css text/css markdown-editor.bundle.js text/javascript}
    if {![dict exists $types $name]} {fail 404 "asset not found"}
    set result [response 200 [read_file [file join $root assets $name] 2097152] \
        "[dict get $types $name]; charset=utf-8"]
    dict set result headers cache-control {public, max-age=3600}
    return $result
}

proc ::web::content::view {config path} {
    set store [dict get $config -store]
    set item [load $store $path]
    set title [dict get $item title]
    if {[dict get $item item_type] eq "folder"} {
        if {[dict get $store kind] eq "blog" && $path eq "/"} {
            set entries [posts $store]
        } else {set entries [children $store $path]}
        set cards {}
        foreach entry $entries {
            append cards [template card.html [list @url@ [url $config [dict get $entry path]] \
                @title@ [escape [dict get $entry title]] @kind@ [dict get $entry item_type] \
                @date@ [dict get $entry published_at]]]
        }
        if {$cards eq {}} {set cards {<p>No published content yet.</p>}}
        set body "<h1>[escape $title]</h1><div class=\"cards\">$cards</div>"
    } else {
        set revisions {}
        foreach revision [history $store $path] {
            append revisions "<li>Revision [dict get $revision revision] · [dict get $revision created_at]</li>"
        }
        set edit {}
        if {[dict get $config -authorize] ne {}} {
            set edit "<a class=\"button\" href=\"[dict get $config -prefix]/_edit$path\">Edit</a>"
        }
        set body [template item.html [list @title@ [escape $title] \
            @parent@ [url $config [dict get $item parent_path]] @edit@ $edit \
            @markdown@ [::cmark_gfm::render_gfm_html [dict get $item markdown]] \
            @date@ [dict get $item published_at] @revisions@ $revisions]]
    }
    response 200 [shell $config $title $body]
}

proc ::web::content::edit {config request context path} {
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
    set body [template edit.html [list @heading@ [escape $title] @title@ [escape [dict get $item title]] \
        @markdown@ [escape [dict get $item markdown]] @csrf@ [escape $token] \
        @revision@ [dict get $item revision] @cancel@ [url $config $path]]]
    response 200 [shell $config $title $body 1]
}

proc ::web::content::dispatch {config action request context params} {
    try {
        switch -- $action {
            asset {return [asset $params]}
            view {return [view $config [request_path $params]]}
            edit {return [edit $config $request $context [request_path $params]]}
        }
    } trap {WEB CONTENT} {message options} {
        return [response [lindex [dict get $options -errorcode] 2] "$message\n" {text/plain; charset=utf-8}]
    }
}
