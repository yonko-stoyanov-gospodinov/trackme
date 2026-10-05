#!/bin/sh
# Starts Claude Code for the customer "vm". trackme groups these sessions under vm.
exec claude --name "vm" "$@"
