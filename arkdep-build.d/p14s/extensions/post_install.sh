#!/usr/bin/bash

systemctl --root="$workdir" preset-all
systemctl --root="$workdir" --global preset-all
