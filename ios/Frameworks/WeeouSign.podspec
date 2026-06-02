Pod::Spec.new do |s|
  s.name         = 'WeeouSign'
  s.version      = '1.0.0'
  s.summary      = 'Prebuilt API signing static library for Shortplay iOS'
  s.homepage     = 'https://github.com/user/shortplay'
  s.license      = { :type => 'Proprietary' }
  s.author       = 'Shortplay'
  s.source       = { :path => '.' }
  s.platform     = :ios, '13.0'

  s.vendored_frameworks = 'WeeouSign.xcframework'
  s.static_framework = true

  s.pod_target_xcconfig = {
    'OTHER_LDFLAGS' => '-ObjC -all_load'
  }
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '-ObjC -all_load -Wl,-exported_symbol,_weeou_sign',
    'STRIP_INSTALLED_PRODUCT' => 'NO'
  }
end
