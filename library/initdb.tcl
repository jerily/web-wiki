# Explicit schema setup on a caller-owned connection; safe to repeat.
proc ::web::wiki::initdb {connection} {::web::content::initdb $connection}
