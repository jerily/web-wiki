# Register this mount's manifest routes on the supplied router.
proc ::web::wiki::mount {router args} {
    init_templates
    set config [::web::core::options [dict create -store {} -prefix /wiki -authorize {} -csrf {} -navigation {} -context {} -render-markdown {} -config {}] {*}$args]
    set settings [::web::core::options {master_template {} templates {} allow_create false} {*}[dict get $config -config]]
    if {![string is boolean -strict [dict get $settings allow_create]]} {
        error "allow_create must be a boolean"
    }
    dict set config -config $settings
    set available [page_templates $config]
    dict for {name text} $available {
        ::jinja2::validate $text -templates $available -path $name
    }
    set store [dict get $config -store]
    if {$store eq {} || [dict get $store kind] ne "wiki"} {error "-store must be a wiki store"}
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
    set manifest [::web::core::manifest web-wiki]
    set plan [::web::core::route_plan $manifest $prefix $config $settings]
    ::web::core::install $router $plan
    return $config
}
