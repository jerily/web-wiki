namespace eval ::web::content {
    variable templates {}
}

proc ::web::content::init_templates {} {
    variable root
    variable templates
    if {[dict size $templates]} {return}
    set loaded {}
    foreach filename [glob -directory [file join $root assets] *.html.jinja] {
        dict set loaded [file tail $filename] [read_file $filename]
    }
    dict for {name text} $loaded {
        ::jinja2::validate $text -templates $loaded -path $name
    }
    set templates $loaded
}

# All text is explicitly typed; arrays and booleans are never inferred from strings.
proc ::web::content::text_fields {dictionary} {
    set fields {}
    dict for {key value} $dictionary {dict set fields $key [list S $value]}
    return $fields
}

proc ::web::content::rows_field {rows} {
    set values {}
    foreach row $rows {lappend values [list M [text_fields $row]]}
    return [list L $values]
}

proc ::web::content::render_page {config name fields {extraTemplates {}}} {
    variable templates
    init_templates
    set navigation {}
    foreach link [dict get $config -navigation] {
        lassign $link label href
        lappend navigation [dict create label $label href $href]
    }
    set context [text_fields [dict create brand [dict get $config -store -title] \
        home [url $config /] assets [dict get $config -prefix]/_assets]]
    dict set context navigation [rows_field $navigation]
    dict set context editing {BOOL 0}
    set context [dict merge $context $fields]
    # Extra templates come from the trusted host, never a request or content row.
    set available [dict merge $templates $extraTemplates]
    ::jinja2::render [dict get $available $name] \
        [::tjson::typed_to_json [list M $context]] -templates $available -path $name
}
