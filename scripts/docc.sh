xcodebuild docbuild -scheme tap-guard -destination 'generic/platform=macOS' -derivedDataPath "$PWD/.derivedData"
$(xcrun --find docc) process-archive \
  transform-for-static-hosting "$PWD/.derivedData/Build/Products/Debug/TapGuard.doccarchive" \
  --output-path docs \
  --hosting-base-path "tap-guard"

echo "<script>window.location.href += \"/documentation/tapguard\"</script>" > docs/index.html;
