# Explicit maintenance operation. Mounting and handling requests never create schema.
proc ::web::wiki::initdb {connection} {
    set identity {
        domain {type varchar length 253 not_null 1}
        path {type varchar length 1024 not_null 1}
    }
    set items [db_define_table web_wiki_items [dict merge $identity {
        parent_path {type text not_null 1}
        item_type {type varchar length 16 not_null 1}
        title {type text not_null 1}
        markdown {type text not_null 1}
        source_path {type text not_null 1}
        source_markdown {type text not_null 1}
        revision {type integer not_null 1}
        active {type boolean not_null 1}
        updated_at {type varchar length 32 not_null 1}
    }] -primary_key {domain path}]
    set revisions [db_define_table web_wiki_revisions [dict merge $identity {
        revision {type integer not_null 1}
        title {type text not_null 1}
        markdown {type text not_null 1}
        created_at {type varchar length 32 not_null 1}
    }] -primary_key {domain path revision}]
    db_create_table $connection $items -if_not_exists 1
    db_create_table $connection $revisions -if_not_exists 1
    # Filter a folder before sorting its children; avoid indexing large titles
    # and a second full path alongside parent_path in PostgreSQL index tuples.
    db_create_index $connection web_wiki_children web_wiki_items {domain parent_path active} -if_not_exists 1
}
