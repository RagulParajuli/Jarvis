# Keep rules for the release build (R8/ProGuard).
#
# Flutter, WebRTC and several plugins reach classes only through reflection or
# JNI, so R8 has to be told not to rename or remove them. These rules add no
# code; they only protect what is already there.

# Flutter embedding and the generated plugin registrant.
-keep class io.flutter.** { *; }
-keep class dev.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

# Flutter's Play Store deferred-component support is referenced by the engine
# but only used by apps that ship split features. This one does not, so R8 can
# leave the classes out instead of failing the build.
-dontwarn com.google.android.play.core.**

# LiveKit client and the WebRTC native bridge.
-keep class org.webrtc.** { *; }
-keep class io.livekit.** { *; }
-keep class livekit.** { *; }
-keep class com.livekit.** { *; }
-keep class com.cloudwebrtc.webrtc.** { *; }
-dontwarn org.webrtc.**
-dontwarn com.cloudwebrtc.webrtc.**

# Background execution service and device bridge.
-keep class de.julianassmann.flutter_background.** { *; }
-keep class com.livekit.example.VoiceAssistantFlutter.** { *; }

# url_launcher, flutter_dotenv and the JSON/JWT helpers.
-keep class io.flutter.plugins.urllauncher.** { *; }
-keep class io.flutter.plugins.flutterdotenv.** { *; }
