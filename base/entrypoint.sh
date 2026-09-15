#!/bin/sh
set -e
envsubst < /bootstrap.yml.template > /tmp/bootstrap.yml
exec patroni /tmp/bootstrap.yml