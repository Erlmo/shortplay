Pod::Spec.new do |s|
  s.name         = 'WeeouSign'
  s.version      = '1.0.0'
  s.summary      = 'Prebuilt API signing static library for Shortplay iOS/macOS'
  s.homepage     = 'https://github.com/user/shortplay'
  s.license      = { :type => 'Proprietary' }
  s.author       = 'Shortplay'
  s.source       = { :path => '.' }
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'

  s.vendored_frameworks = 'WeeouSign.xcframework'
  s.static_framework = true

  s.pod_target_xcconfig = {
    'OTHER_LDFLAGS' => '-ObjC -all_load'
  }
  s.ios.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '-ObjC -all_load -Wl,-exported_symbol,_weeou_sign',
    'STRIP_INSTALLED_PRODUCT' => 'NO'
  }
  # macOS 不限制导出符号：Xcode 的 Debug 构建把 app 主体放进
  # *.debug.dylib，导出白名单会把它的入口函数也隐藏掉，启动即崩溃。
  # 不加白名单时 weeou_sign 本来就是全局可见的，dlsym 能找到。
  s.osx.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '-ObjC -all_load',
    'STRIP_INSTALLED_PRODUCT' => 'NO'
  }
end
