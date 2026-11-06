# Public web package entry point: ::web::<name>::mount, in library/mount.tcl.
proc ::web::wiki::mount {router args} {
    ::web::content::mount wiki $router {*}$args
}
proc ::web::wiki::create {args} {::web::content::create wiki {*}$args}
proc ::web::wiki::sync {store directory} {::web::content::sync $store $directory}
proc ::web::wiki::load {store path} {::web::content::load $store $path}
proc ::web::wiki::children {store path} {::web::content::children $store $path}
proc ::web::wiki::history {store path} {::web::content::history $store $path}
proc ::web::wiki::save {store path title markdown revision} {
    ::web::content::save $store $path $title $markdown $revision
}
