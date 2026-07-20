#!/bin/bash
lpm run --ephemeral --config='
core.reload_module("colors.onedark")' \
./ db json onedark language_psql
