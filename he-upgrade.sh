#!/bin/bash
hermes profile list && auto-upgrade.sh && hermes update && hermes doctor --fix && hermes profile list
