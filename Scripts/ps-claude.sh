#!/bin/sh
# Starts Claude Code for the customer "ps". trackme groups these sessions under ps.
exec claude --name "ps" "$@"
