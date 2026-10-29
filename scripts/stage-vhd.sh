#!/bin/bash
# Runs as a deployment script (AzureCLI). Copies one <definition>-<version>.vhd from the
# warehouse into the staging account, server side. Azure builds gallery images only from a
# VHD in the same subscription, so the image version is made from the staged copy.
#
# in:  DEFINITION, VERSION (latest or x.y.z), WH_ACCOUNT, WH_CONTAINER, WH_SAS, ST_ACCOUNT, ST_KEY, STORAGE_SUFFIX
# out: version, blob, uri, nes, stack, built
set -euo pipefail
SAS="${WH_SAS#\?}"

if [ "$VERSION" = "latest" ]; then
  BLOB=$(az storage blob list --account-name "$WH_ACCOUNT" --container-name "$WH_CONTAINER" --sas-token "$SAS" \
           --query "[].name" -o tsv | grep -E "^${DEFINITION}-[0-9]+\.[0-9]+\.[0-9]+\.vhd$" | sort -V | tail -1 || true)
  if [ -z "$BLOB" ]; then
    echo "No ${DEFINITION}-<version>.vhd in $WH_ACCOUNT/$WH_CONTAINER. The SAS needs read and list on that container." >&2
    exit 1
  fi
else
  BLOB="${DEFINITION}-${VERSION}.vhd"
fi
VER="${BLOB#"${DEFINITION}"-}"; VER="${VER%.vhd}"
echo "using $BLOB"

st() { az storage blob "$@" --account-name "$ST_ACCOUNT" --account-key "$ST_KEY"; }

copy() { st show --container-name vhd --name "$BLOB" --query "properties.copy.$1" -o tsv 2>/dev/null || true; }

state=$(copy status)
case "$state" in
  success) echo "$BLOB is already staged" ;;
  pending) echo "$BLOB is still being copied by an earlier run" ;;
  *)
    echo "copying $BLOB into $ST_ACCOUNT (server side)"
    st copy start --destination-blob "$BLOB" --destination-container vhd \
       --source-uri "https://$WH_ACCOUNT.blob.$STORAGE_SUFFIX/$WH_CONTAINER/$BLOB?$SAS" -o none
    state=pending ;;
esac
while [ "$state" = "pending" ]; do
  sleep 15
  state=$(copy status)
  echo "  $state $(copy progress)"
done
if [ "$state" != "success" ]; then
  echo "copy of $BLOB ended ${state:-with no copy state}" >&2
  exit 1
fi

# the warehouse blob's metadata (nes, stack, built) becomes the image version's tags
md=$(az storage blob metadata show --account-name "$WH_ACCOUNT" --container-name "$WH_CONTAINER" --name "$BLOB" --sas-token "$SAS" -o json 2>/dev/null || echo '{}')
jq -n --arg version "$VER" --arg blob "$BLOB" --arg uri "https://$ST_ACCOUNT.blob.$STORAGE_SUFFIX/vhd/$BLOB" --argjson md "$md" \
  '{version: $version, blob: $blob, uri: $uri, nes: ($md.nes // ""), stack: ($md.stack // ""), built: ($md.built // "")}' > "$AZ_SCRIPTS_OUTPUT_PATH"
cat "$AZ_SCRIPTS_OUTPUT_PATH"
