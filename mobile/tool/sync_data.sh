#!/bin/sh
# Copies the exchange data the extension keeps (src/server) into the app's assets.
cd "$(dirname "$0")/.." && cp ../src/server/exchangeWallets.json ../src/server/exchangeTokens.json assets/data/
