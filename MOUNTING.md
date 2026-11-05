# Web package mount contract

Every web package provides `::web::<name>::mount` in **`library/mount.tcl`**. The Tcl package name is `web-<name>`; use an underscore in the namespace component if a future name contains additional hyphens. The package loader sources this file. `web-wiki` and `web-blog` are the reference implementations.

```tcl
package require web-wiki
package require web-blog
::web::wiki::mount $router -store $wiki -prefix /wiki
::web::blog::mount $router -store $blog -prefix /blog
```

The first positional argument is an existing `tpathexp` router. Remaining arguments are named option/value pairs. Mount registers fully qualified command prefixes and returns its configuration. It does not create, destroy or dispatch the router, open a listening socket, initialize a schema, sync content, or commit a caller's transaction. Mount once during interpreter initialization, before a host catch-all; register the most specific prefixes first. There is no unmount API in `tpathexp`; destroy the router to release registrations.

| Shared option | Contract |
| --- | --- |
| `-store` | Required store created by that package; connection remains caller-owned |
| `-prefix` | Default `/wiki` or `/blog`; canonical absolute slug path, or `/` for a root mount |
| `-authorize` | Optional command prefix; required with `-csrf` to enable editing |
| `-csrf` | Optional command prefix; required with `-authorize` |
| `-navigation` | List of `{label /local-path}` pairs for the page header |

Call `create` with `-connection`, optional `-domain`, and optional `-title`. Store instances isolate content by package collection and domain. Sharing a connection across wiki/blog instances in one interpreter is supported. A root mount consumes all otherwise unmatched GET paths, so register it last.

| Relative route | Method | Behavior |
| --- | --- | --- |
| `/` (also the prefix itself) | GET/HEAD | Wiki folder index or newest-first blog index |
| `/<path>` | GET/HEAD | Render an active item |
| `/_assets/<asset>` | GET/HEAD | Serve an allowlisted CSS or JavaScript asset |
| `/_edit/<path>` | GET/HEAD | Authorized editor form |
| `/_edit/<path>` | POST | Authorized, CSRF-checked revision save; 303 to item |

The underscore route segments are reserved and cannot collide with imported slugs. Request and response dictionaries follow `tpathexp`: handlers receive `request context params` and return `statusCode`, `headers`, and `body`. HEAD bodies and 404/405 routing are handled by the router. The host retains the original request fields, authentication context and headers when dispatching.

Authorization callback:

```tcl
proc can_edit {request context action path} {
    # action is "edit" or "save"; path is canonical and relative to the mount.
    expr {[dict exists $context role] && [dict get $context role] eq "editor"}
}
```

CSRF callback contract: `callback issue request context {}` returns a nonempty token tied to the authenticated session; `callback verify request context submittedToken` returns a boolean. The host supplies session storage and token generation. Callback errors propagate to the host's error handler. False authorization or CSRF verification returns 403. Missing editor policy returns 404. The example site's Basic authentication challenge is a host feature.

POST accepts `application/x-www-form-urlencoded` fields `title`, `markdown`, `revision` and `csrf`. Lambda `isBase64Encoded` bodies are supported. Duplicate fields, missing fields, invalid encodings and oversize content are rejected. Content errors use Tcl error codes `{WEB CONTENT <HTTP-status>}` and are converted by handlers; unexpected errors remain visible to the host.

The shared `::web::content` implementation is distributed with `web-wiki`; `web-blog` reuses it explicitly. Future packages should follow this entry-point contract without copying the shared renderer/editor or taking over host lifecycle responsibilities.
