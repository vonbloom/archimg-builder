#!/bin/sh
case "$-" in
*i*)
    case "$(tty 2>/dev/null)" in
    /dev/tty[0-9]*)
        TMOUT=600
        readonly TMOUT
        export TMOUT
        ;;
    esac
    ;;
esac
