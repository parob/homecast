# THIS FILE IS AUTO-GENERATED. DO NOT MODIFY!!

# Copyright 2020-2023 Tauri Programme within The Commons Conservancy
# SPDX-License-Identifier: Apache-2.0
# SPDX-License-Identifier: MIT

-keep class cloud.homecast.app.* {
  native <methods>;
}

-keep class cloud.homecast.app.WryActivity {
  public <init>(...);

  void setWebView(cloud.homecast.app.RustWebView);
  java.lang.Class getAppClass(...);
  java.lang.String getVersion();
}

-keep class cloud.homecast.app.Ipc {
  public <init>(...);

  @android.webkit.JavascriptInterface public <methods>;
}

-keep class cloud.homecast.app.RustWebView {
  public <init>(...);

  void loadUrlMainThread(...);
  void loadHTMLMainThread(...);
  void evalScript(...);
}

-keep class cloud.homecast.app.RustWebChromeClient,cloud.homecast.app.RustWebViewClient {
  public <init>(...);
}
