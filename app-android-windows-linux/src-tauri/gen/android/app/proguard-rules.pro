# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

# Uncomment this to preserve the line number information for
# debugging stack traces.
#-keepattributes SourceFile,LineNumberTable

# If you keep the line number information, uncomment this to
# hide the original source file name.
#-renamesourcefileattribute SourceFile

# The @JavascriptInterface bridges the web app calls into. AGP's default rules
# already keep these, but release builds minify (isMinifyEnabled = true) and a
# stripped method fails silently at runtime rather than at build time — the web
# app just sees an undefined function. State the requirement explicitly.
-keepclassmembers class cloud.homecast.app.MainActivity$PushBridge {
    @android.webkit.JavascriptInterface <methods>;
}
-keepclassmembers class cloud.homecast.app.MainActivity$StatusBarBridge {
    @android.webkit.JavascriptInterface <methods>;
}
-keepclassmembers class cloud.homecast.app.MainActivity$DiscoveryBridge {
    @android.webkit.JavascriptInterface <methods>;
}
