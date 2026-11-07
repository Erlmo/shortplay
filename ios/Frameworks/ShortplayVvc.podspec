Pod::Spec.new do |s|
  s.name = 'ShortplayVvc'
  s.version = '1.0.0'
  s.summary = 'iOS VVC software decoder with a CoreVideo frame bridge'
  s.homepage = 'https://github.com/fraunhoferhhi/vvdec'
  s.license = { :type => 'BSD-3-Clause-Clear', :file => 'VVdeC/LICENSE.txt' }
  s.author = 'Shortplay'
  s.source = { :path => '.' }
  s.ios.deployment_target = '15.0'
  s.source_files = 'VVdeC/Source/*.{h,mm}'
  s.public_header_files = 'VVdeC/Source/SPVvcDecoder.h'
  s.vendored_frameworks = 'VVdeC/VVdeC.xcframework'
  s.frameworks = 'CoreVideo', 'Foundation'
  s.libraries = 'c++'
  s.static_framework = true
  s.pod_target_xcconfig = { 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17' }
  s.resource_bundles = { 'VVdeCNotices' => ['VVdeC/LICENSE.txt', 'VVdeC/NOTICE.txt'] }
end
