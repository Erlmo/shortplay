Pod::Spec.new do |s|
  s.name = 'ShortplayVvc'
  s.version = '1.0.0'
  s.summary = 'macOS VVC software decoder with a CoreVideo frame bridge'
  s.homepage = 'https://github.com/fraunhoferhhi/vvdec'
  s.license = { :type => 'BSD-3-Clause-Clear', :file => 'LICENSE.txt' }
  s.author = 'Shortplay'
  s.source = { :path => '.' }
  s.osx.deployment_target = '10.15'
  s.source_files = 'Source/*.{h,mm}'
  s.public_header_files = 'Source/SPVvcDecoder.h'
  s.vendored_libraries = 'libvvdec.a'
  s.frameworks = 'CoreVideo', 'Foundation'
  s.libraries = 'c++'
  s.static_framework = true
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/include"'
  }
  s.resource_bundles = { 'VVdeCNotices' => ['LICENSE.txt', 'NOTICE.txt'] }
end
