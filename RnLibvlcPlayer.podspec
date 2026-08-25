require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name         = "RnLibvlcPlayer"
  s.version      = package['version']
  s.summary      = package['description']
  s.license      = "MIT"
  s.homepage     = "https://github.com"
  s.authors      = "JeedomConnect"

  s.platforms    = { :ios => "16.0" }
  # Never actually fetched — this package is only ever consumed locally via
  # the app's "file:" dependency + CocoaPods autolinking's :path resolution
  # (same as every other package here), so this URL doesn't need to resolve.
  # CocoaPods' spec validation just wants a non-empty :source.
  s.source       = { :git => "https://github.com/jeedomconnect/rn-libvlc-player.git", :tag => "v#{s.version}" }
  s.static_framework = true

  s.source_files = "ios/**/*.{h,m,mm}"

  # Switched from MobileVLCKit 3.7.3 (the newest 3.x release available on
  # CocoaPods — no 3.7.4/3.7.5 exists there, so this couldn't be fixed by
  # bumping) to VLCKit 4.x after on-device debugging traced a persistent
  # "plays briefly, then flaps Playing<->Buffering forever" symptom to 3.x's
  # architecture: buffering is one of the states in VLCMediaPlayerState
  # there, so any buffering blip force-exits Playing — repeatedly, for any
  # live RTSP feed with normal jitter. VLCKit 4.x's VLCMediaPlayerDelegate
  # has a *separate* -mediaPlayerBufferingChanged: callback that doesn't
  # touch -mediaPlayerStateChanged: at all (see RnLibvlcPlayerView.mm's
  # header comment for the full story). Still alpha (VideoLAN-maintained,
  # actively iterated — a23 as of this writing), so this is a real risk
  # trade-off, not a strictly-safer choice; expo-libvlc-player already ships
  # on it as prior art.
  s.dependency "VLCKit", "4.0.0a23"

  install_modules_dependencies(s)
end
