#!/usr/bin/env bash
# 手搓 APK（不装 gradle）：javac → d8 → aapt2 link → 塞 dex → zipalign → apksigner debug 签名
set -euo pipefail
cd "$(dirname "$0")"

SDK=/Users/longfei/android-dev/sdk
BT=$SDK/build-tools/34.0.0
PLATFORM=$SDK/platforms/android-32/android.jar
JAVA_HOME=/Users/longfei/android-dev/jdk/jdk-17.0.20.1+1/Contents/Home
export PATH=$JAVA_HOME/bin:$PATH

rm -rf out && mkdir -p out/classes

javac -source 11 -target 11 -Xlint:-options -classpath "$PLATFORM" -d out/classes $(find src -name '*.java')
"$BT/d8" --lib "$PLATFORM" --output out $(find out/classes -name '*.class')

"$BT/aapt2" link -o out/base.apk -I "$PLATFORM" --manifest AndroidManifest.xml
cd out && zip -q base.apk classes.dex && cd ..

"$BT/zipalign" -f 4 out/base.apk out/aligned.apk

# debug 签名密钥（没有就现造一个，只用于测试侧载）
KS=out/debug.keystore
[ -f "$KS" ] || "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KS" -storepass android -keypass android \
    -alias probe -dname "CN=GlassProbe" -keyalg RSA -keysize 2048 -validity 3650 >/dev/null 2>&1
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
    --out out/GlassProbe.apk out/aligned.apk

ls -la out/GlassProbe.apk
echo "✓ APK: $(pwd)/out/GlassProbe.apk"
