# flutter_local_notifications persists every scheduled alarm with Gson, so the
# boot receiver and repeating alarms can re-arm them. R8 strips the generic
# signatures Gson's TypeToken reads, which makes the plugin throw "Missing type
# parameter" in release builds only: alarms silently never arm, and cancelling
# throws too. Debug builds are not minified, so everything looks fine there.
#
# Rules from https://github.com/google/gson/blob/main/examples/android-proguard-example/proguard.cfg

-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses

-dontwarn sun.misc.**

-keep class com.google.gson.reflect.TypeToken
-keep class * extends com.google.gson.reflect.TypeToken
-keep public class * implements java.lang.reflect.Type

-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer

-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}

# The plugin's own models are what Gson serialises; their field names are the
# stored JSON keys, so renaming them breaks alarms saved by a previous build.
-keep class com.dexterous.** { *; }
