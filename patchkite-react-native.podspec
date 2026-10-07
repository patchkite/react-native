require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "patchkite-react-native"
  s.module_name  = "PatchkiteReactNative"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://github.com/patchkite/react-native"
  s.license      = package["license"]
  s.authors      = "Patchkite"
  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => "https://github.com/patchkite/react-native.git", :tag => "v#{s.version}" }
  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.swift_version = "5.9"
  s.frameworks   = "Security", "CryptoKit"
  s.libraries    = "compression"
  s.pod_target_xcconfig = { "DEFINES_MODULE" => "YES" }

  install_modules_dependencies(s)
end
