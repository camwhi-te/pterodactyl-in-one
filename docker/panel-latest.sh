#!/bin/sh
# Print the tag of the latest stable (non-prerelease) Pterodactyl panel release.
# Follows the github.com redirect rather than the API to avoid rate limits.
curl -fsSL -m 15 -o /dev/null -w '%{url_effective}' \
    https://github.com/pterodactyl/panel/releases/latest | sed -n 's|.*/releases/tag/||p'
