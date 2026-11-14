# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

# Explicit maintenance operation. Mounting and handling requests never create schema.
proc ::web::wiki::initdb {connection} {
    variable root
    db_apply_schema $connection [file join $root sql schema.json] -additive true
}
