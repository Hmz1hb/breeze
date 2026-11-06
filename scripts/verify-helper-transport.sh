#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
identity="${BREEZE_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity=$(security find-identity -v -p codesigning | awk '/Apple Development:/{print $2; exit}')
fi
[[ -n "$identity" && "$identity" != "-" ]] || { print -u2 "An Apple signing identity is required."; exit 1; }
out="${PWD}/.build/helper-transport"
mkdir -p "$out"
xcrun clang -Wall -Wextra -Werror -Wno-unused-parameter -I Sources/CHardware/include Tests/HelperTransport/main.c Sources/CHardware/Hardware.c -framework IOKit -framework Security -framework CoreFoundation -o "$out/server"
cp "$out/server" "$out/breeze-client"
cp "$out/server" "$out/other-client"
cp "$out/server" "$out/adhoc-client"
codesign --force --options runtime --sign "$identity" --identifier local.breeze.fancontrol.helper "$out/server"
codesign --force --options runtime --sign "$identity" --identifier local.breeze.fancontrol "$out/breeze-client"
codesign --force --options runtime --sign "$identity" --identifier local.breeze.unrelated "$out/other-client"
codesign --force --sign - --identifier local.breeze.fancontrol "$out/adhoc-client"
"$out/server" "$out/breeze-client" 1 local.breeze.fancontrol
"$out/server" "$out/other-client" 0 local.breeze.fancontrol
"$out/server" "$out/adhoc-client" 0 local.breeze.fancontrol
"$out/server" "$out/breeze-client" 0 arbitrary.identifier
