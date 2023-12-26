Pod::Spec.new do |s|
  s.name             = 'DebFileResolver'
  s.version          = '1.0.0'
  s.summary          = 'Deb file resolver'
  s.homepage         = 'https://github.com/YangBies/DebFileResolver'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'hy' => '.com' }
  s.source        = {:git => 'https://github.com/YangBies/DebFileResolver.git', :tag => s.version}
  s.ios.deployment_target = '11.0'
  s.source_files = 'DebFileResolver/Core/**/*.{m,h}'
  s.project_header_files = 'DebFileResolver/Core/lzma/*.h'
  s.frameworks = 'Foundation'
  s.libraries = "z", "bz2", "lzma"
  s.vendored_libraries = 'DebFileResolver/Libs/libdpkg.a'
end
