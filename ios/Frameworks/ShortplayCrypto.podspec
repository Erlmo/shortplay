Pod::Spec.new do |s|
  s.name         = 'ShortplayCrypto'
  s.version      = '1.0.0'
  s.summary      = 'Prebuilt crypto static library for Shortplay iOS'
  s.homepage     = 'https://github.com/user/shortplay'
  s.license      = { :type => 'Proprietary' }
  s.author       = 'Shortplay'
  s.source       = { :path => '.' }
  s.platform     = :ios, '13.0'

  s.vendored_frameworks = 'ShortplayCrypto.xcframework'
  s.static_framework = true

  s.pod_target_xcconfig = {
    'OTHER_LDFLAGS' => '-ObjC -all_load'
  }
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '-ObjC -all_load',
    'HEADER_SEARCH_PATHS' => '"${PODS_ROOT}/../../ios/Frameworks/include"'
  }
end
